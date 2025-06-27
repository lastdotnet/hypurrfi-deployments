// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title IERC3156FlashBorrower
 * @notice Interface for ERC3156 flash loan borrowers
 */
interface IERC3156FlashBorrower {
    /**
     * @notice Callback function called by the flash lender
     * @param initiator The address that initiated the flash loan
     * @param token The address of the token borrowed
     * @param amount The amount of tokens borrowed
     * @param fee The fee to be paid for the flash loan
     * @param data Additional data passed to the flash loan
     * @return success The keccak256 hash of "IERC3156FlashBorrower.onFlashLoan"
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32 success);
} 