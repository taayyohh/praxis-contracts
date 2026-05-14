// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ArtistRegistryV1 {
    struct Artist {
        string domain;
        uint256 registeredAt;
    }

    mapping(address => Artist) public artists;
    address[] public registeredAddresses;

    event Registered(address indexed wallet, string domain);

    function register(string calldata domain) external {
        require(bytes(domain).length > 0, "empty domain");
        require(bytes(artists[msg.sender].domain).length == 0, "already registered");

        artists[msg.sender] = Artist(domain, block.timestamp);
        registeredAddresses.push(msg.sender);

        emit Registered(msg.sender, domain);
    }

    function allArtists() external view returns (address[] memory wallets, string[] memory domains) {
        uint256 len = registeredAddresses.length;
        wallets = new address[](len);
        domains = new string[](len);

        for (uint256 i = 0; i < len; i++) {
            wallets[i] = registeredAddresses[i];
            domains[i] = artists[registeredAddresses[i]].domain;
        }
    }

    function totalArtists() external view returns (uint256) {
        return registeredAddresses.length;
    }
}
