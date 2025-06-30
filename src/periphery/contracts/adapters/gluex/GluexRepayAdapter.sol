// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20WithPermit} from '@aave/core-v3/contracts/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {SafeERC20, IERC20} from 'lib/solidity-utils/src/contracts/oz-common/SafeERC20.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {BaseGluexBuyAdapter} from './BaseGluexBuyAdapter.sol';
import {ReentrancyGuard} from '@aave/periphery-v3/contracts/dependencies/openzeppelin/ReentrancyGuard.sol';
import {IERC3156FlashBorrower} from '../../misc/flashloan/interfaces/IERC3156FlashBorrower.sol';
import {Ownable} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/Ownable.sol';

/**
 * @title GluexRepayAdapter
 * @notice Gluex Adapter to perform a repay of a debt with collateral.
 * @author Last Labs
 **/
contract GluexRepayAdapter is BaseGluexBuyAdapter, ReentrancyGuard, IERC3156FlashBorrower {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

  struct RepayParams {
    address collateralAsset;
    uint256 collateralAmount;
    uint256 rateMode;
    PermitSignature permitSignature;
    bool useEthPath;
  }

  struct FlashLoanData {
    IERC20 debtAsset;
    IERC20 collateralAsset;
    uint256 debtRepayAmount;
    uint256 collateralAmount;
    uint256 rateMode;
    bytes gluexData;
    PermitSignature permitSignature;
    address user;
  }

  constructor(
    IPoolAddressesProvider addressesProvider,
    address gluexRouter,
    address owner
  ) BaseGluexBuyAdapter(addressesProvider, gluexRouter) {
    transferOwnership(owner);
  }

  /**
   * @dev Initiates a flash loan to repay debt with collateral
   * @param collateralAsset Address of the collateral asset to flash borrow
   * @param debtAsset Address of the debt asset to repay
   * @param collateralAmount Amount of collateral to flash borrow
   * @param debtRepayAmount Amount of debt to repay
   * @param rateMode Rate mode of the debt (1 for stable, 2 for variable)
   * @param gluexData Data for Gluex Router
   * @param permitSignature Permit signature for hyToken transfer
   */
  function flashLoanAndRepay(
    IERC20 collateralAsset,
    IERC20 debtAsset,
    uint256 collateralAmount,
    uint256 debtRepayAmount,
    uint256 rateMode,
    bytes calldata gluexData,
    PermitSignature calldata permitSignature
  ) external nonReentrant {
    // Determine the actual debt to cover
    uint256 actualDebtRepayAmount = getDebtRepayAmount(
      debtAsset,
      rateMode,
      debtRepayAmount,
      msg.sender
    );

    FlashLoanData memory flashData = FlashLoanData({
      debtAsset: debtAsset,
      collateralAsset: collateralAsset,
      debtRepayAmount: actualDebtRepayAmount,
      collateralAmount: collateralAmount,
      rateMode: rateMode,
      gluexData: gluexData,
      permitSignature: permitSignature,
      user: msg.sender
    });

    // Flash loan the debt asset for the amount to cover
    POOL.flashLoanSimple(
      address(this),
      address(debtAsset),
      actualDebtRepayAmount,
      abi.encode(flashData),
      0
    );
  }

  /**
   * @dev Flash loan callback function - executes the repay operation
   * @param initiator The address of the flashloan initiator
   * @param token The address of the flash-borrowed asset (debt asset)
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
    require(msg.sender == address(POOL), 'CALLER_MUST_BE_POOL');
    require(initiator == address(this), 'INITIATOR_MUST_BE_THIS_CONTRACT');

    // Decode data: (flashData)
    FlashLoanData memory flashData = abi.decode(data, (FlashLoanData));

    // Repay debt first using the flash loaned debt tokens
    IERC20(token).safeApprove(address(POOL), flashData.debtRepayAmount);
    POOL.repay(address(token), flashData.debtRepayAmount, flashData.rateMode, flashData.user);
    IERC20(token).safeApprove(address(POOL), 0);

    // Pull hyTokens (collateral) from user
    _pullHyTokenAndWithdraw(address(flashData.collateralAsset), flashData.user, flashData.collateralAmount, flashData.permitSignature);

    // Swap collateral to debt asset to repay the flash loan
    (uint256 amountSold, uint256 amountBought) = _buyOnGluex(
      flashData.gluexData,
      flashData.collateralAsset,
      IERC20(token)
    );

    // Calculate total debt to cover (flash loan amount + fee)
    uint256 totalDebtToCover = amount.add(fee);

    // Verify we got enough debt asset to cover the flash loan
    require(amountBought >= totalDebtToCover, "INSUFFICIENT_DEBT_ASSET_SWAPPED");

    // Approve flash loan repayment
    IERC20(token).safeApprove(address(POOL), totalDebtToCover);

    // Transfer excess debt asset to the user
    uint256 debtAssetExcess = amountBought - totalDebtToCover;
    if (debtAssetExcess > 0) {
      IERC20(token).safeTransfer(flashData.user, debtAssetExcess);
    }

    // Transfer excess collateral back to the user
    uint256 collateralExcess = flashData.collateralAmount - amountSold;
    if (collateralExcess > 0) {
      // Deposit excess collateral back to the pool for the user
      IERC20(flashData.collateralAsset).safeApprove(address(POOL), collateralExcess);
      POOL.deposit(address(flashData.collateralAsset), collateralExcess, flashData.user, 0);
      IERC20(flashData.collateralAsset).safeApprove(address(POOL), 0);
    }

    return CALLBACK_SUCCESS;
  }

  /**
   * @dev Swaps the user collateral for the debt asset and then repay the debt on the protocol on behalf of the user
   * without using flash loans. This method can be used when the temporary transfer of the collateral asset to this
   * contract does not affect the user position.
   * The user should give this contract allowance to pull the hyTokens in order to withdraw the underlying asset
   * @param collateralAsset Address of asset to be swapped
   * @param debtAsset Address of debt asset
   * @param collateralAmount max Amount of the collateral to be swapped
   * @param debtRepayAmount Amount of the debt to be repaid, or maximum amount when repaying entire debt
   * @param gluexData Data for Gluex Router
   * @param permitSignature struct containing the permit signature
   */
  function swapAndRepay(
    IERC20 collateralAsset,
    IERC20 debtAsset,
    uint256 collateralAmount,
    uint256 debtRepayAmount,
    bytes calldata gluexData,
    PermitSignature calldata permitSignature
  ) external nonReentrant {
    debtRepayAmount = getDebtRepayAmount(
      debtAsset,
      2, // Variable rate mode only
      debtRepayAmount,
      msg.sender
    );

    // Pull hyTokens from user
    _pullHyTokenAndWithdraw(address(collateralAsset), msg.sender, collateralAmount, permitSignature);
    
    //buy debt asset using collateral asset
    (uint256 amountSold, uint256 amountBought) = _buyOnGluex(
      gluexData,
      collateralAsset,
      debtAsset
    );

    uint256 collateralBalanceLeft = collateralAmount - amountSold;

    //deposit collateral back in the pool, if left after the swap(buy)
    if (collateralBalanceLeft > 0) {
      IERC20(collateralAsset).safeApprove(address(POOL), collateralBalanceLeft);
      POOL.deposit(address(collateralAsset), collateralBalanceLeft, msg.sender, 0);
      IERC20(collateralAsset).safeApprove(address(POOL), 0);
    }

    // Repay debt. Approves 0 first to comply with tokens that implement the anti frontrunning approval fix
    IERC20(debtAsset).safeApprove(address(POOL), debtRepayAmount);
    POOL.repay(address(debtAsset), debtRepayAmount, 2, msg.sender); // Variable rate mode only
    IERC20(debtAsset).safeApprove(address(POOL), 0);

    {
      //transfer excess of debtAsset back to the user, if any
      uint256 debtAssetExcess = amountBought - debtRepayAmount;
      if (debtAssetExcess > 0) {
        IERC20(debtAsset).safeTransfer(msg.sender, debtAssetExcess);
      }
    }
  }

  /**
   * @dev Pull hyTokens from user and withdraw underlying asset
   * @param reserve Address of the reserve asset
   * @param user Address of the user
   * @param amount Amount of hyTokens to pull
   * @param permitSignature Permit signature for hyToken transfer
   */
  function _pullHyTokenAndWithdraw(
    address reserve,
    address user,
    uint256 amount,
    PermitSignature memory permitSignature
  ) internal override {
    IERC20WithPermit reserveHyToken = IERC20WithPermit(
      _getReserveData(address(reserve)).aTokenAddress
    );
    _pullHyTokenAndWithdraw(reserve, reserveHyToken, user, amount, permitSignature);
  }

  /**
   * @dev Pull hyTokens from user and withdraw underlying asset
   * @param reserve Address of the reserve asset
   * @param reserveHyToken Address of the hyToken
   * @param user Address of the user
   * @param amount Amount of hyTokens to pull
   * @param permitSignature Permit signature for hyToken transfer
   */
  function _pullHyTokenAndWithdraw(
    address reserve,
    IERC20WithPermit reserveHyToken,
    address user,
    uint256 amount,
    PermitSignature memory permitSignature
  ) internal override {
    // If deadline is set to zero, assume there is no signature for permit
    if (permitSignature.deadline != 0) {
      reserveHyToken.permit(
        user,
        address(this),
        permitSignature.amount,
        permitSignature.deadline,
        permitSignature.v,
        permitSignature.r,
        permitSignature.s
      );
    }

    // transfer hyTokens from user to adapter
    IERC20(address(reserveHyToken)).safeTransferFrom(user, address(this), amount);

    // withdraw reserve
    require(POOL.withdraw(reserve, amount, address(this)) == amount, 'UNEXPECTED_AMOUNT_WITHDRAWN');
  }

  function getDebtRepayAmount(
    IERC20 debtAsset,
    uint256 rateMode,
    uint256 debtRepayAmount,
    address initiator
  ) private view returns (uint256) {
    DataTypes.ReserveData memory debtReserveData = _getReserveData(address(debtAsset));

    address debtToken = DataTypes.InterestRateMode(rateMode) == DataTypes.InterestRateMode.STABLE
      ? debtReserveData.stableDebtTokenAddress
      : debtReserveData.variableDebtTokenAddress;

    uint256 currentDebt = IERC20(debtToken).balanceOf(initiator);

    require(debtRepayAmount <= currentDebt, 'INVALID_DEBT_REPAY_AMOUNT');

    return debtRepayAmount;
  }
}