// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20WithPermit} from '@aave/core-v3/contracts/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {SafeERC20, IERC20} from 'lib/solidity-utils/src/contracts/oz-common/SafeERC20.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {BaseGluexBuyAdapter} from './BaseGluexBuyAdapter.sol';
import {ReentrancyGuard} from '@aave/periphery-v3/contracts/dependencies/openzeppelin/ReentrancyGuard.sol';
import {BorrowAllowanceLib} from './libraries/BorrowAllowanceLib.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';
import {IERC3156FlashBorrower} from '../../misc/flashloan/interfaces/IERC3156FlashBorrower.sol';
import {Ownable} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/Ownable.sol';

/**
 * @title GluexDebtSwapAdapter
 * @notice Gluex Adapter to perform a swap of debt assets.
 * @author Last Labs
 **/
contract GluexDebtSwapAdapter is BaseGluexBuyAdapter, ReentrancyGuard, IERC3156FlashBorrower {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using BorrowAllowanceLib for IPool;

  bytes32 public constant CALLBACK_SUCCESS = keccak256('ERC3156FlashBorrower.onFlashLoan');

  // Constant for variable debt interest rate mode
  uint256 internal constant VARIABLE_INTEREST_RATE_MODE = 2;

  struct FlashLoanData {
    IERC20 fromDebtAsset;
    IERC20 toDebtAsset;
    uint256 fromDebtAmount;
    uint256 toDebtAmountMax;
    address user;
    bytes gluexData; // Add Gluex swap data
  }

  constructor(
    IPoolAddressesProvider addressesProvider,
    address gluexRouter,
    address owner
  ) BaseGluexBuyAdapter(addressesProvider, gluexRouter) {
    transferOwnership(owner);
  }

  /**
   * @dev Initiates a flash loan to swap debt assets
   * @param fromDebtAsset Address of the debt asset to swap from
   * @param toDebtAsset Address of the debt asset to swap to
   * @param fromDebtAmount Amount of from debt to swap
   * @param toDebtAmountMax Maximum amount of to debt asset to borrow
   * @param gluexData Gluex swap data for swapping toDebtAsset to fromDebtAsset
   */
  function flashLoanAndSwapDebt(
    IERC20 fromDebtAsset,
    IERC20 toDebtAsset,
    uint256 fromDebtAmount,
    uint256 toDebtAmountMax,
    bytes calldata gluexData
  ) external nonReentrant {
    // Get the actual debt amount to swap
    uint256 actualFromDebtAmount = getDebtAmount(
      fromDebtAsset,
      fromDebtAmount,
      msg.sender
    );

    FlashLoanData memory flashData = FlashLoanData({
      fromDebtAsset: fromDebtAsset,
      toDebtAsset: toDebtAsset,
      fromDebtAmount: actualFromDebtAmount,
      toDebtAmountMax: toDebtAmountMax,
      user: msg.sender,
      gluexData: gluexData
    });

    // Prepare arrays for flash loan
    address[] memory assets = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    uint256[] memory interestRateModes = new uint256[](1);

    assets[0] = address(toDebtAsset);
    amounts[0] = toDebtAmountMax;
    interestRateModes[0] = VARIABLE_INTEREST_RATE_MODE;

    // Step 1: Flash loan the to debt asset using the full flashLoan function
    POOL.flashLoan(
      address(this),           // receiverAddress
      assets,                  // assets array
      amounts,                 // amounts array
      interestRateModes,       // interestRateModes array (variable)
      address(this),           // onBehalfOf (this contract)
      abi.encode(flashData),   // params
      0                        // referralCode
    );
  }

  /**
   * @dev Flash loan callback function - executes the debt swap operation
   * @param initiator The address of the flashloan initiator
   * @param token The address of the flash-borrowed asset (toDebtAsset)
   * @param amount The amount of the flash-borrowed asset
   * @param fee The fee of the flash-borrowed asset
   * @param data The byte-encoded params passed when initiating the flashloan
   * @return success The keccak256 hash of "IERC3156FlashBorrower.onFlashLoan"
   */
  function onFlashLoan(
    address initiator,
    address token,
    uint256 amount,
    uint256 fee,
    bytes calldata data
  ) external override returns (bytes32 success) {
    token; fee;
    require(msg.sender == address(POOL), 'CALLER_MUST_BE_POOL');
    require(initiator == address(this), 'INITIATOR_MUST_BE_THIS_CONTRACT');

    // Decode data: (flashData)
    FlashLoanData memory flashData = abi.decode(data, (FlashLoanData));

    // Step 1: Swap the flash-loaned toDebtAsset for fromDebtAsset on Gluex
    (uint256 amountSold, uint256 amountBought) = _buyOnGluex(
      flashData.gluexData,
      flashData.toDebtAsset,
      flashData.fromDebtAsset
    );

    // Step 2: Repay the fromDebtAsset debt using the swapped tokens
    require(amountBought >= flashData.fromDebtAmount, 'INSUFFICIENT_FROM_DEBT_ASSET_RECEIVED');
    
    flashData.fromDebtAsset.safeApprove(address(POOL), flashData.fromDebtAmount);
    POOL.repay(address(flashData.fromDebtAsset), flashData.fromDebtAmount, VARIABLE_INTEREST_RATE_MODE, flashData.user);
    flashData.fromDebtAsset.safeApprove(address(POOL), 0);

    // Step 3: Use any remaining toDebtAsset to repay the flash loan
    // Any shortfall becomes the user's new debt in toDebtAsset
    uint256 remainingToDebtAsset = amount - amountSold;
    if (remainingToDebtAsset > 0) {
      flashData.toDebtAsset.safeApprove(address(POOL), remainingToDebtAsset);
      POOL.repay(address(flashData.toDebtAsset), remainingToDebtAsset, VARIABLE_INTEREST_RATE_MODE, flashData.user);
      flashData.toDebtAsset.safeApprove(address(POOL), 0);
    }

    return CALLBACK_SUCCESS;
  }

  /**
   * @dev Swaps the user's debt for another debt asset without using flash loans.
   * This method can be used when the user has sufficient collateral to cover the debt swap.
   * @param fromDebtAsset Address of the debt asset to swap from
   * @param toDebtAsset Address of the debt asset to swap to
   * @param fromDebtAmount Amount of the from debt to be swapped
   * @param toDebtAmountMax Maximum amount of to debt asset to borrow
   */
  function swapDebt(
    IERC20 fromDebtAsset,
    IERC20 toDebtAsset,
    uint256 fromDebtAmount,
    uint256 toDebtAmountMax
  ) external nonReentrant {
    // Always variable debt
    uint256 actualFromDebtAmount = getDebtAmount(
      fromDebtAsset,
      fromDebtAmount,
      msg.sender
    );

    // Validate that the amount to borrow doesn't exceed the maximum allowed
    require(actualFromDebtAmount <= toDebtAmountMax, 'EXCEEDS_MAX_DEBT_AMOUNT');

    // Transfer tokens from user to this contract for repay
    fromDebtAsset.safeTransferFrom(msg.sender, address(this), actualFromDebtAmount);

    // Repay the from debt (variable rate mode = VARIABLE_INTEREST_RATE_MODE)
    IERC20(fromDebtAsset).safeApprove(address(POOL), actualFromDebtAmount);
    POOL.repay(address(fromDebtAsset), actualFromDebtAmount, VARIABLE_INTEREST_RATE_MODE, msg.sender);
    IERC20(fromDebtAsset).safeApprove(address(POOL), 0);

    // Check for sufficient borrow allowance using the library directly
    require(
      IPool(POOL).getBorrowAllowance(address(toDebtAsset), msg.sender) >= actualFromDebtAmount,
      'INSUFFICIENT_BORROW_ALLOWANCE'
    );

    // Borrow the to debt asset using borrow delegation (variable debt only, rateMode = VARIABLE_INTEREST_RATE_MODE)
    POOL.borrow(address(toDebtAsset), actualFromDebtAmount, VARIABLE_INTEREST_RATE_MODE, 0, msg.sender);
  }

  /**
   * @dev Get the actual debt amount for a given debt asset (variable debt only)
   * @param debtAsset Address of the debt asset
   * @param debtAmount Requested debt amount
   * @param user Address of the user
   * @return Actual debt amount
   */
  function getDebtAmount(
    IERC20 debtAsset,
    uint256 debtAmount,
    address user
  ) private view returns (uint256) {
    uint256 currentDebt = POOL.getVariableDebtBalance(address(debtAsset), user);
    require(debtAmount <= currentDebt, 'INVALID_DEBT_AMOUNT');
    
    // If requested amount is within 1% of current debt, use current debt (to account for interest)
    // Otherwise, use the requested amount
    uint256 onePercentThreshold = currentDebt / 100; // 1% of current debt
    uint256 difference = currentDebt - debtAmount;
    
    if (difference <= onePercentThreshold) {
      return currentDebt; // Use current debt to account for interest
    } else {
      return debtAmount; // Use requested amount
    }
  }
}