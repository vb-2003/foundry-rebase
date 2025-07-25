// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract Vault {
    // CUSTOM ERRORS

    error Vault__RedeemFailed();

    // STATE VARIABLES

    IRebaseToken private immutable i_rebaseToken;

    // EVENTS

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    // FUNCTIONS

    /**
     * @notice Constructor to initialize the Vault contract with the RebaseToken address.
     * @param _rebaseToken The address of the RebaseToken contract.
     */
    constructor(IRebaseToken _rebaseToken) {
        i_rebaseToken = _rebaseToken;
    }

    /**
     * @notice Allows users to deposit Ether into the vault.
     * @dev Mints RebaseTokens equivalent to the deposited Ether amount.
     */
    function deposit() external payable {
        uint256 interestRate = i_rebaseToken.getInterestRate();
        i_rebaseToken.mint(msg.sender, msg.value, interestRate);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Fallback function to receive Ether.
     */
    receive() external payable {}

    /**
     * @notice Allows users to redeem their RebaseTokens for Ether.
     * @param _amount The amount of RebaseTokens to redeem.
     * @dev Burns the specified amount of RebaseTokens and transfers the equivalent Ether back to the user.
     */
    function redeem(uint256 _amount) external {
        if (_amount == type(uint256).max) {
            _amount = i_rebaseToken.balanceOf(msg.sender);
        }
        i_rebaseToken.burn(msg.sender, _amount);
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            revert Vault__RedeemFailed();
        }
        emit Redeem(msg.sender, _amount);
    }

    /**
     * @notice Returns the address of the RebaseToken contract.
     * @return The address of the RebaseToken contract.
     */
    function getRebaseTokenAddress() external view returns (address) {
        return address(i_rebaseToken);
    }
}
