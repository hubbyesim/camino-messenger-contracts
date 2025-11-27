// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

// --- OpenZeppelin imports (upgradeable version) ---
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { ERC721URIStorageUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

// --- Interface to your BookingToken for linking options ---
interface IBookingToken {
    function ownerOf(uint256 tokenId) external view returns (address);

    function linkOptionToBooking(
        uint256 bookingTokenId,
        address optionContract,
        uint256 optionTokenId,
        bytes32 optionType
    ) external;
}

/**
 * @title BookingOptionToken
 * @notice Upgradeable ERC-721 contract representing "options" attached to a booking,
 *         e.g. extra baggage, insurance, lounge access, etc.
 *
 * Options are standard NFTs that can be:
 *  - minted to any address using `mintOption`
 *  - or minted directly to the owner of a BookingToken and linked on-chain
 *    via `mintOptionForBooking`.
 */
contract BookingOptionToken is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /***************************************************
     *                     ROLES                       *
     ***************************************************/

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /***************************************************
     *                    STORAGE                      *
     ***************************************************/

    // Simple incremental tokenId counter
    uint256 private _nextTokenId;

    // Option type per token (e.g. keccak256("EXTRA_BAGGAGE"), "INSURANCE", etc.)
    mapping(uint256 tokenId => bytes32 optionType) private _optionTypes;

    // Storage gap for future upgrades (adjust size as you like)
    uint256[48] private __gap;

    /***************************************************
     *                     EVENTS                      *
     ***************************************************/

    event OptionMinted(
        uint256 indexed tokenId,
        address indexed to,
        bytes32 optionType
    );

    event OptionMintedForBooking(
        uint256 indexed bookingTokenId,
        uint256 indexed optionTokenId,
        address indexed bookingToken,
        bytes32 optionType
    );

    /***************************************************
     *                   INITIALIZER                   *
     ***************************************************/

    /**
     * @notice Initializes the upgradeable BookingOptionToken contract.
     *
     * @param admin Address that will receive DEFAULT_ADMIN_ROLE, MINTER_ROLE and UPGRADER_ROLE
     * @param name_ ERC-721 token name
     * @param symbol_ ERC-721 token symbol
     */
    function initialize(
        address admin,
        string memory name_,
        string memory symbol_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721URIStorage_init();
        __AccessControl_init();
        // No __UUPSUpgradeable_init() — it does not exist / is not needed

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /***************************************************
     *                   MINT LOGIC                    *
     ***************************************************/

    /**
     * @notice Mints a generic option NFT to a given address.
     *
     * @param to Recipient of the option NFT
     * @param uri Metadata URI of this option token
     * @param optionType_ Arbitrary type identifier, e.g. keccak256("EXTRA_BAGGAGE")
     *
     * @return tokenId Newly minted token id
     */
    function mintOption(
        address to,
        string memory uri,
        bytes32 optionType_
    ) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
        _optionTypes[tokenId] = optionType_;

        emit OptionMinted(tokenId, to, optionType_);
    }

    /**
     * @notice Mints an option NFT "for a booking":
     *  - Looks up the owner of the BookingToken
     *  - Mints the option NFT to that owner
     *  - Calls `linkOptionToBooking` on the BookingToken contract
     *
     * @param bookingToken Address of the BookingToken contract
     * @param bookingTokenId Token id of the booking
     * @param uri Metadata URI of the option NFT
     * @param optionType_ Arbitrary type identifier, e.g. keccak256("EXTRA_BAGGAGE")
     *
     * @return optionTokenId Newly minted option token id
     */
    function mintOptionForBooking(
        address bookingToken,
        uint256 bookingTokenId,
        string memory uri,
        bytes32 optionType_
    ) external onlyRole(MINTER_ROLE) returns (uint256 optionTokenId) {
        IBookingToken booking = IBookingToken(bookingToken);

        // 1) Get the booking owner
        address bookingOwner = booking.ownerOf(bookingTokenId);

        // 2) Mint option NFT to booking owner
        optionTokenId = _nextTokenId++;
        _safeMint(bookingOwner, optionTokenId);
        _setTokenURI(optionTokenId, uri);
        _optionTypes[optionTokenId] = optionType_;

        emit OptionMinted(optionTokenId, bookingOwner, optionType_);

        // 3) Link it on-chain in the BookingToken contract
        booking.linkOptionToBooking(
            bookingTokenId,
            address(this),
            optionTokenId,
            optionType_
        );

        emit OptionMintedForBooking(
            bookingTokenId,
            optionTokenId,
            bookingToken,
            optionType_
        );
    }

    /***************************************************
     *                  VIEW HELPERS                   *
     ***************************************************/

    /**
     * @notice Returns the optionType associated with a given token.
     *
     * @param tokenId Option token id
     * @return optionType_ The type identifier for this option
     */
    function getOptionType(
        uint256 tokenId
    ) external view returns (bytes32 optionType_) {
        optionType_ = _optionTypes[tokenId];
    }

    /***************************************************
     *              UUPS UPGRADE AUTH                  *
     ***************************************************/

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /***************************************************
     *               ERC-721 OVERRIDES                 *
     ***************************************************/

    /**
     * @notice Core hook used by modern OZ ERC721 for mint/transfer/burn.
     *
     * We hook here to detect burns (to == address(0)) and clean up _optionTypes.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override(ERC721Upgradeable)
        returns (address from)
    {
        from = super._update(to, tokenId, auth);

        if (to == address(0)) {
            // Token is being burned, clean up extra storage
            delete _optionTypes[tokenId];
        }
    }

    function tokenURI(
        uint256 tokenId
    )
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
