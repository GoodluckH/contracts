// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

// Interface
import { IDropERC721 } from "../interfaces/drop/IDropERC721.sol";

// Token
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";

// Access Control + security
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

// Meta transactions
import "../openzeppelin-presets/metatx/ERC2771ContextUpgradeable.sol";

// Utils
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "../lib/CurrencyTransferLib.sol";
import "../lib/FeeType.sol";
import "../lib/MerkleProof.sol";

// Helper interfaces
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/BitMapsUpgradeable.sol";

// Thirdweb top-level
import "../interfaces/ITWFee.sol";

contract DropERC721 is
    Initializable,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    MulticallUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC721EnumerableUpgradeable,
    IDropERC721
{
    using BitMapsUpgradeable for BitMapsUpgradeable.BitMap;
    using StringsUpgradeable for uint256;

    bytes32 private constant MODULE_TYPE = bytes32("DropERC721");
    uint256 private constant VERSION = 1;

    /// @dev Only TRANSFER_ROLE holders can participate in transfers, when transfers are restricted.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can lazy mint NFTs.
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @dev Max bps in the thirdweb system
    uint256 private constant MAX_BPS = 10_000;

    /// @dev The address interpreted as native token of the chain.
    address private constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev The thirdweb contract with fee related information.
    ITWFee public immutable thirdwebFee;

    /// @dev Owner of the contract (purpose: OpenSea compatibility, etc.)
    address private _owner;

    /// @dev The next token ID of the NFT to "lazy mint".
    uint256 public nextTokenIdToMint;

    /// @dev The next token ID of the NFT that can be claimed.
    uint256 public nextTokenIdToClaim;

    /// @dev The adress that receives all primary sales value.
    address public primarySaleRecipient;

    /// @dev The max number of claim per wallet.
    uint256 public maxWalletClaimCount;

    /// @dev Token max total supply for the collection.
    uint256 public maxTotalSupply;

    /// @dev The adress that receives all primary sales value.
    address private platformFeeRecipient;

    /// @dev The recipient of who gets the royalty.
    address private royaltyRecipient;

    /// @dev The percentage of royalty how much royalty in basis points.
    uint128 private royaltyBps;

    /// @dev The % of primary sales collected by the contract as fees.
    uint128 private platformFeeBps;

    /// @dev Contract level metadata.
    string public contractURI;

    /// @dev end indices of each batch of tokens with the same baseURI
    uint256[] public baseURIIndices;

    /// @dev Mapping from 'end token Id' => URI that overrides `baseURI + tokenId` convention.
    mapping(uint256 => string) private baseURI;

    /// @dev End token Id => info related to the delayed reveal of the baseURI
    mapping(uint256 => bytes) public encryptedBaseURI;

    /// @dev Mapping from address => number of NFTs a wallet claimed.
    mapping(address => uint256) public walletClaimCount;

    /// @dev Token ID => royalty recipient and bps for token
    mapping(uint256 => RoyaltyInfo) private royaltyInfoForToken;

    ClaimConditionList public claimCondition;

    constructor(address _thirdwebFee) initializer {
        thirdwebFee = ITWFee(_thirdwebFee);
    }

    /// @dev Initiliazes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address _trustedForwarder,
        address _saleRecipient,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        uint128 _platformFeeBps,
        address _platformFeeRecipient
    ) external initializer {
        // Initialize inherited contracts, most base-like -> most derived.
        __ReentrancyGuard_init();
        __ERC2771Context_init(_trustedForwarder);
        __ERC721_init(_name, _symbol);

        // Initialize this contract's state.
        royaltyRecipient = _royaltyRecipient;
        royaltyBps = _royaltyBps;
        platformFeeRecipient = _platformFeeRecipient;
        platformFeeBps = _platformFeeBps;
        primarySaleRecipient = _saleRecipient;
        contractURI = _contractURI;

        _owner = _defaultAdmin;
        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, address(0));
    }

    ///     =====   Public functions  =====

    /// @dev Returns the module type of the contract.
    function contractType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function contractVersion() external pure returns (uint8) {
        return uint8(VERSION);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return hasRole(DEFAULT_ADMIN_ROLE, _owner) ? _owner : address(0);
    }

    /// @dev Returns the URI for a given tokenId.
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        for (uint256 i = 0; i < baseURIIndices.length; i += 1) {
            if (_tokenId < baseURIIndices[i]) {
                if (encryptedBaseURI[baseURIIndices[i]].length != 0) {
                    return string(abi.encodePacked(baseURI[baseURIIndices[i]], "0"));
                } else {
                    return string(abi.encodePacked(baseURI[baseURIIndices[i]], _tokenId.toString()));
                }
            }
        }

        return "";
    }

    /// @dev At any given moment, returns the uid for the active claim condition.
    function getActiveClaimConditionId() public view returns (uint256) {
        for (uint256 i = claimCondition.currentStartId + claimCondition.count; i > claimCondition.currentStartId; i--) {
            if (block.timestamp >= claimCondition.phases[i - 1].startTimestamp) {
                return i - 1;
            }
        }

        revert("no active mint condition.");
    }

    /// @dev See: https://ethereum.stackexchange.com/questions/69825/decrypt-message-on-chain
    function encryptDecrypt(bytes memory data, bytes calldata key) public pure returns (bytes memory result) {
        // Store data length on stack for later use
        uint256 length = data.length;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Set result to free memory pointer
            result := mload(0x40)
            // Increase free memory pointer by lenght + 32
            mstore(0x40, add(add(result, length), 32))
            // Set result length
            mstore(result, length)
        }

        // Iterate over the data stepping by 32 bytes
        for (uint256 i = 0; i < length; i += 32) {
            // Generate hash of the key and offset
            bytes32 hash = keccak256(abi.encodePacked(key, i));

            bytes32 chunk;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Read 32-bytes data chunk
                chunk := mload(add(data, add(i, 32)))
            }
            // XOR the chunk with hash
            chunk ^= hash;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Write 32-byte encrypted chunk
                mstore(add(result, add(i, 32)), chunk)
            }
        }
    }

    /// @dev Checks whether a request to claim tokens obeys the active mint condition.
    function verifyClaim(
        uint256 _conditionId,
        address _claimer,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken
    ) public view {
        ClaimCondition memory currentClaimPhase = claimCondition.phases[_conditionId];

        require(
            _currency == currentClaimPhase.currency && _pricePerToken == currentClaimPhase.pricePerToken,
            "invalid currency or price specified."
        );
        require(
            _quantity > 0 && _quantity <= currentClaimPhase.quantityLimitPerTransaction,
            "invalid quantity claimed."
        );
        require(
            currentClaimPhase.supplyClaimed + _quantity <= currentClaimPhase.maxClaimableSupply,
            "exceed max mint supply."
        );
        require(nextTokenIdToClaim + _quantity <= nextTokenIdToMint, "not enough minted tokens.");
        require(maxTotalSupply == 0 || nextTokenIdToClaim + _quantity <= maxTotalSupply, "exceed max total supply.");
        require(
            maxWalletClaimCount == 0 || walletClaimCount[_claimer] + _quantity <= maxWalletClaimCount,
            "exceed claim limit for wallet"
        );

        (uint256 lastClaimTimestamp, uint256 nextValidClaimTimestamp) = getClaimTimestamp(_conditionId, _claimer);
        require(lastClaimTimestamp == 0 || block.timestamp >= nextValidClaimTimestamp, "cannot claim yet.");
    }

    function verifyClaimMerkleProof(
        uint256 _conditionId,
        address _claimer,
        uint256 _quantity,
        bytes32[] calldata _proofs,
        uint256 _proofMaxQuantityPerTransaction
    ) public view returns (bool validMerkleProof, uint256 merkleProofIndex) {
        ClaimCondition memory currentClaimPhase = claimCondition.phases[_conditionId];

        if (currentClaimPhase.merkleRoot != bytes32(0)) {
            (validMerkleProof, merkleProofIndex) = MerkleProof.verify(
                _proofs,
                currentClaimPhase.merkleRoot,
                keccak256(abi.encodePacked(_claimer, _proofMaxQuantityPerTransaction))
            );
            require(validMerkleProof, "not in whitelist.");
            require(!claimCondition.limitMerkleProofClaim[_conditionId].get(merkleProofIndex), "proof claimed.");
            require(
                _proofMaxQuantityPerTransaction == 0 || _quantity <= _proofMaxQuantityPerTransaction,
                "invalid quantity proof."
            );
        }
    }

    ///     =====   External functions  =====

    /// @dev See EIP-2981
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        virtual
        returns (address receiver, uint256 royaltyAmount)
    {
        (address recipient, uint256 bps) = getRoyaltyInfoForToken(tokenId);
        receiver = recipient;
        royaltyAmount = (salePrice * bps) / MAX_BPS;
    }

    /**
     *  @dev Lets an account with `MINTER_ROLE` mint tokens of ID from `nextTokenIdToMint`
     *       to `nextTokenIdToMint + _amount - 1`. The URIs for these tokenIds is baseURI + `${tokenId}`.
     */
    function lazyMint(
        uint256 _amount,
        string calldata _baseURIForTokens,
        bytes calldata _encryptedBaseURI
    ) external onlyRole(MINTER_ROLE) {
        uint256 startId = nextTokenIdToMint;
        uint256 baseURIIndex = startId + _amount;

        nextTokenIdToMint = baseURIIndex;
        baseURI[baseURIIndex] = _baseURIForTokens;
        baseURIIndices.push(baseURIIndex);

        if (_encryptedBaseURI.length != 0) {
            encryptedBaseURI[baseURIIndex] = _encryptedBaseURI;
        }

        emit TokensLazyMinted(startId, startId + _amount - 1, _baseURIForTokens, _encryptedBaseURI);
    }

    /// @dev Lets an account with `MINTER_ROLE` reveal the URI for the relevant NFTs.
    function reveal(uint256 index, bytes calldata _key)
        external
        onlyRole(MINTER_ROLE)
        returns (string memory revealedURI)
    {
        require(index < baseURIIndices.length, "invalid index.");

        uint256 _index = baseURIIndices[index];
        bytes memory encryptedURI = encryptedBaseURI[_index];
        require(encryptedURI.length != 0, "nothing to reveal.");

        revealedURI = string(encryptDecrypt(encryptedURI, _key));

        baseURI[_index] = revealedURI;
        delete encryptedBaseURI[_index];

        emit NFTRevealed(_index, revealedURI);

        return revealedURI;
    }

    /// @dev Lets an account claim a given quantity of tokens, of a single tokenId, according to claim conditions.
    function claim(
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        bytes32[] calldata _proofs,
        uint256 _proofMaxQuantityPerTransaction
    ) external payable nonReentrant {
        uint256 tokenIdToClaim = nextTokenIdToClaim;

        // Get the claim conditions.
        uint256 activeConditionId = getActiveClaimConditionId();

        // Verify claim validity. If not valid, revert.
        verifyClaim(activeConditionId, _msgSender(), _quantity, _currency, _pricePerToken);

        (bool validMerkleProof, uint256 merkleProofIndex) = verifyClaimMerkleProof(
            activeConditionId,
            _msgSender(),
            _quantity,
            _proofs,
            _proofMaxQuantityPerTransaction
        );

        // if the current claim condition and has a merkle root and the provided proof is valid
        // if validMerkleProof is false, it means that claim condition does not have a merkle root
        // if invalid proof is provided, the verifyClaimMerkleProof would fail on require.
        if (validMerkleProof) {
            claimCondition.limitMerkleProofClaim[activeConditionId].set(merkleProofIndex);
        }

        // If there's a price, collect price.
        collectClaimPrice(_quantity, _currency, _pricePerToken);

        // Mint the relevant tokens to claimer.
        transferClaimedTokens(_receiver, activeConditionId, _quantity);

        emit TokensClaimed(activeConditionId, _msgSender(), _receiver, tokenIdToClaim, _quantity);
    }

    /// @dev Lets a module admin set claim conditions.
    function setClaimConditions(ClaimCondition[] calldata _phases, bool _resetLimitRestriction)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 existingStartIndex = claimCondition.currentStartId;
        uint256 existingPhaseCount = claimCondition.count;

        // if it's to reset restriction, all new claim phases would start at the end of the existing batch.
        // otherwise, the new claim phases would override the existing phases and limits from the existing start index
        uint256 newStartIndex = existingPhaseCount;
        if (_resetLimitRestriction) {
            newStartIndex = existingStartIndex + existingPhaseCount;
        }

        uint256 lastConditionStartTimestamp;
        for (uint256 i = 0; i < _phases.length; i++) {
            require(
                lastConditionStartTimestamp == 0 || lastConditionStartTimestamp < _phases[i].startTimestamp,
                "startTimestamp must be in ascending order."
            );

            claimCondition.phases[newStartIndex + i] = _phases[i];
            claimCondition.phases[newStartIndex + i].supplyClaimed = 0;

            lastConditionStartTimestamp = _phases[i].startTimestamp;
        }

        // freeing up claim phases and claim limit
        // if we are resetting restriction, then we'd clean up previous batch maps
        // if we are not, then we'd only clean up unused claim phases and limits.
        if (_resetLimitRestriction) {
            for (uint256 i = 0; i < existingPhaseCount; i++) {
                delete claimCondition.phases[existingStartIndex + i];
                delete claimCondition.limitMerkleProofClaim[existingStartIndex + i];
                // can't delete limitLastClaimTimestamp because we don't have addresses
            }
        } else {
            // if there are more old (existing) phases than the newly set ones, delete all the remaining
            // unused phases and limits
            // if there are more new phases than old phases, then we'd only need to set the `length` properly
            if (existingPhaseCount > _phases.length) {
                for (uint256 i = _phases.length; i < existingPhaseCount; i++) {
                    delete claimCondition.phases[newStartIndex + i];
                    delete claimCondition.limitMerkleProofClaim[newStartIndex + i];
                    // can't delete limitLastClaimTimestamp because we don't have addresses
                }
            }
        }

        claimCondition.count = _phases.length;
        claimCondition.currentStartId = newStartIndex;

        emit ClaimConditionsUpdated(_phases);
    }

    //      =====   Setter functions  =====

    /// @dev Lets a module admin set a claim limit on a wallet.
    function setWalletClaimCount(address _claimer, uint256 _count) external onlyRole(DEFAULT_ADMIN_ROLE) {
        walletClaimCount[_claimer] = _count;
        emit WalletClaimCountUpdated(_claimer, _count);
    }

    /// @dev Lets a module admin set a maximum number of claim per wallet.
    function setMaxWalletClaimCount(uint256 _count) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxWalletClaimCount = _count;
        emit MaxWalletClaimCountUpdated(_count);
    }

    /// @dev Lets a module admin set the maximum number of supply for the collection.
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxTotalSupply = _maxTotalSupply;
        emit MaxTotalSupplyUpdated(_maxTotalSupply);
    }

    /// @dev Lets a module admin set the default recipient of all primary sales.
    function setPrimarySaleRecipient(address _saleRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        primarySaleRecipient = _saleRecipient;
        emit PrimarySaleRecipientUpdated(_saleRecipient);
    }

    /// @dev Lets a module admin update the royalty bps and recipient.
    function setDefaultRoyaltyInfo(address _royaltyRecipient, uint256 _royaltyBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_royaltyBps <= MAX_BPS, "exceed royalty bps");

        royaltyRecipient = _royaltyRecipient;
        royaltyBps = uint128(_royaltyBps);

        emit DefaultRoyalty(_royaltyRecipient, _royaltyBps);
    }

    /// @dev Lets a module admin set the royalty recipient for a particular token Id.
    function setRoyaltyInfoForToken(
        uint256 _tokenId,
        address _recipient,
        uint256 _bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bps <= MAX_BPS, "exceed royalty bps");

        royaltyInfoForToken[_tokenId] = RoyaltyInfo({ recipient: _recipient, bps: _bps });

        emit RoyaltyForToken(_tokenId, _recipient, _bps);
    }

    /// @dev Lets a module admin update the fees on primary sales.
    function setPlatformFeeInfo(address _platformFeeRecipient, uint256 _platformFeeBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_platformFeeBps <= MAX_BPS, "bps <= 10000.");

        platformFeeBps = uint64(_platformFeeBps);
        platformFeeRecipient = _platformFeeRecipient;

        emit PlatformFeeInfoUpdated(_platformFeeRecipient, _platformFeeBps);
    }

    /// @dev Lets a module admin set a new owner for the contract. The new owner must be a module admin.
    function setOwner(address _newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(DEFAULT_ADMIN_ROLE, _newOwner), "new owner not module admin.");
        address _prevOwner = _owner;
        _owner = _newOwner;

        emit OwnerUpdated(_prevOwner, _newOwner);
    }

    /// @dev Lets a module admin set the URI for contract-level metadata.
    function setContractURI(string calldata _uri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractURI = _uri;
    }

    //      =====   Getter functions  =====

    /// @dev Returns the platform fee bps and recipient.
    function getPlatformFeeInfo() external view returns (address, uint16) {
        return (platformFeeRecipient, uint16(platformFeeBps));
    }

    /// @dev Returns the platform fee bps and recipient.
    function getDefaultRoyaltyInfo() external view returns (address, uint16) {
        return (royaltyRecipient, uint16(royaltyBps));
    }

    /// @dev Returns the royalty recipient for a particular token Id.
    function getRoyaltyInfoForToken(uint256 _tokenId) public view returns (address, uint16) {
        RoyaltyInfo memory royaltyForToken = royaltyInfoForToken[_tokenId];

        return
            royaltyForToken.recipient == address(0)
                ? (royaltyRecipient, uint16(royaltyBps))
                : (royaltyForToken.recipient, uint16(royaltyForToken.bps));
    }

    /// @dev Returns the timestamp for next available claim for a claimer address
    function getClaimTimestamp(uint256 _conditionId, address _claimer)
        public
        view
        returns (uint256 lastClaimTimestamp, uint256 nextValidClaimTimestamp)
    {
        lastClaimTimestamp = claimCondition.limitLastClaimTimestamp[_conditionId][_claimer];

        unchecked {
            nextValidClaimTimestamp =
                lastClaimTimestamp +
                claimCondition.phases[_conditionId].waitTimeInSecondsBetweenClaims;

            if (nextValidClaimTimestamp < lastClaimTimestamp) {
                nextValidClaimTimestamp = type(uint256).max;
            }
        }
    }

    /// @dev Returns the  mint condition for a given tokenId, at the given index.
    function getClaimConditionById(uint256 _conditionId) external view returns (ClaimCondition memory condition) {
        condition = claimCondition.phases[_conditionId];
    }

    /// @dev Returns the amount of stored baseURIs
    function getBaseURICount() external view returns (uint256) {
        return baseURIIndices.length;
    }

    //      =====   Internal functions  =====

    /// @dev Collects and distributes the primary sale value of tokens being claimed.
    function collectClaimPrice(
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal {
        if (_pricePerToken == 0) {
            return;
        }

        uint256 totalPrice = _quantityToClaim * _pricePerToken;
        uint256 platformFees = (totalPrice * platformFeeBps) / MAX_BPS;
        (address twFeeRecipient, uint256 twFeeBps) = thirdwebFee.getFeeInfo(address(this), FeeType.PRIMARY_SALE);
        uint256 twFee = (totalPrice * twFeeBps) / MAX_BPS;

        if (_currency == NATIVE_TOKEN) {
            require(msg.value == totalPrice, "must send total price.");
        }

        CurrencyTransferLib.transferCurrency(_currency, _msgSender(), platformFeeRecipient, platformFees);
        CurrencyTransferLib.transferCurrency(_currency, _msgSender(), twFeeRecipient, twFee);
        CurrencyTransferLib.transferCurrency(
            _currency,
            _msgSender(),
            primarySaleRecipient,
            totalPrice - platformFees - twFee
        );
    }

    /// @dev Transfers the tokens being claimed.
    function transferClaimedTokens(
        address _to,
        uint256 _conditionId,
        uint256 _quantityBeingClaimed
    ) internal {
        // Update the supply minted under mint condition.
        claimCondition.phases[_conditionId].supplyClaimed += _quantityBeingClaimed;

        // if transfer claimed tokens is called when to != msg.sender, it'd use msg.sender's limits.
        // behavior would be similar to msg.sender mint for itself, then transfer to `to`.
        claimCondition.limitLastClaimTimestamp[_conditionId][_msgSender()] = block.timestamp;

        // wallet count limit is global, not scoped to the phases
        walletClaimCount[_msgSender()] += _quantityBeingClaimed;

        uint256 tokenIdToClaim = nextTokenIdToClaim;

        for (uint256 i = 0; i < _quantityBeingClaimed; i += 1) {
            _mint(_to, tokenIdToClaim);
            tokenIdToClaim += 1;
        }

        nextTokenIdToClaim = tokenIdToClaim;
    }

    ///     =====   ERC 721 functions  =====

    /// @dev Burns `tokenId`. See {ERC721-_burn}.
    function burn(uint256 tokenId) public virtual {
        //solhint-disable-next-line max-line-length
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721Burnable: caller is not owner nor approved");
        _burn(tokenId);
    }

    /// @dev See {ERC721-_beforeTokenTransfer}.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override(ERC721EnumerableUpgradeable) {
        super._beforeTokenTransfer(from, to, tokenId);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(TRANSFER_ROLE, address(0)) && from != address(0) && to != address(0)) {
            require(hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to), "restricted to TRANSFER_ROLE holders");
        }
    }

    /// @dev See ERC 165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721EnumerableUpgradeable, AccessControlEnumerableUpgradeable, IERC165Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC2981Upgradeable).interfaceId == interfaceId;
    }

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }
}
