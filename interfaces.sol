// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//  ____  ____    __    _  _  ____  ___
// (  _ \(  _ \  /__\  ( \/ )(  _ \/ __)
//  )___/ )   / /(__)\  )  (  )(_) \__ \
// (__)  (_)\_)(__)(__)(_/\_)(____/(___/
//  ____  _  _  ____  ____  ____  ____    __    ___  ____  ___
// (_  _)( \( )(_  _)( ___)(  _ \(  __)  /__\  / __)( ___)/ __)
//  _)(_  )  (  _)(   )__)  )   / )__)  /(__)\ \__ \ )__) \__ \
// (____)(_)\_)(__) (____)(___\_)(__)  (__)(__)  (___/(____)(___/
//
/// @title IArtistRegistry
/// @author @taayyohh
/// @notice Interface for the Praxis artist registry contract
/// @dev Used by downstream contracts to verify artist registration status
interface IArtistRegistry {
    /// @notice Look up an artist by wallet address
    /// @param wallet The artist's wallet address
    /// @return domain The artist's registered domain name
    /// @return registeredAt The timestamp when the artist registered (0 if not registered)
    function artists(address wallet) external view returns (string memory domain, uint256 registeredAt);

    /// @notice Look up a supporter by wallet address
    /// @param wallet The supporter's wallet address
    /// @return handle The supporter's chosen handle
    /// @return registeredAt The timestamp when the supporter registered (0 if not registered)
    function supporters(address wallet) external view returns (string memory handle, uint256 registeredAt);

    /// @notice Check if an address is either a registered artist or supporter
    /// @param wallet The address to check
    /// @return True if the address is a registered artist or supporter
    function isUser(address wallet) external view returns (bool);

    /// @notice Get the deployer address
    /// @return The deployer address
    function deployer() external view returns (address);

    /// @notice Get the current deploy fee
    /// @return The deploy fee in wei
    function deployFee() external view returns (uint256);

    /// @notice Get the orchestrator address (signs EIP-712 redemption authorizations)
    /// @return The orchestrator address
    function orchestrator() external view returns (address);
}

/// @title IPraxisInvites
/// @author @taayyohh
/// @notice Interface for the Praxis invite system contract
/// @dev Used by the Praxis contract to grant invites upon project completion
interface IPraxisInvites {
    /// @notice Grant invite codes to an artist
    /// @param artist The artist's wallet address to receive invites
    /// @param count The number of invites to grant
    function grantInvites(address artist, uint256 count) external;
}
