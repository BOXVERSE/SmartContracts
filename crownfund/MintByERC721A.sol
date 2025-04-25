// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "../../ERC721A/contracts/ERC721A.sol";
import "../../ERC721A/contracts/extensions/ERC721AOwnable.sol";
import "../../ERC721A/contracts/extensions/ERC721AQueryable.sol";
import "../../ERC721A/contracts/extensions/ERC721ABurnable.sol";
import "../../ERC721A/contracts/extensions/ERC4907A.sol";

contract MintByERC721A is ERC721A, ERC721AOwnable, ERC721AQueryable, ERC721ABurnable, ERC4907A {

    string private _contractURI;

    /**
     * @dev Mapping from NFT ID to metadata uri.
     */
    mapping (uint256 => string) internal tokenIdToUri;

    constructor(string memory _mintName, string memory _mintSymbol, string memory contractURI_) ERC721A(_mintName, _mintSymbol) {
        _contractURI = contractURI_;
    }

    function contractURI() public view returns (string memory) {
        return _contractURI;
    }

    function setContractURI(string memory _uri) public onlyOwner {
        _contractURI = _uri;
    }

    function mint(address to, string calldata _uri) external onlyOwner {
        setTokenUri(_nextTokenId(), _uri);
        _safeMint(to, 1);
    }

    /**
     * @notice This is an internal function which should be called from user-implemented external
     * function. Its purpose is to show and properly initialize data structures when using this
     * implementation.
     *
     * @dev Set a distinct URI (RFC 3986) for a given NFT ID.
     * @param _tokenId Id for which we want URI.
     * @param _uri String representing RFC 3986 URI.
     */
    function setTokenUri(uint256 _tokenId, string memory _uri) public onlyOwner {
        tokenIdToUri[_tokenId] = _uri;
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 _tokenId) public view virtual override(ERC721A, IERC721A) returns (string memory) {
        return tokenIdToUri[_tokenId];
    }

    /**
     * Bulk transfer into single transaction
     */
    function bulkSafeTransferFrom(address _from, address _to, uint256[] memory _tokenIds) external {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            safeTransferFrom(_from, _to, _tokenIds[i]);
        }
    }
}
