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
 * @title GluexCollateralSwapAdapter
 * @notice Gluex Adapter to perform a swap of collateral assets.
 * @author Last Labs
 **/
contract GluexCollateralSwapAdapter is BaseGluexBuyAdapter, ReentrancyGuard, IERC3156FlashBorrower {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

  struct SwapParams {
    address fromCollateralAsset;
    address toCollateralAsset;
    uint256 fromCollateralAmount;
    uint256 rateMode;
    PermitSignature permitSignature;
    bool useEthPath;
  }

  struct FlashLoanData {
    IERC20 fromCollateralAsset;
    IERC20 toCollateralAsset;
    uint256 fromCollateralAmount;
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
   * @dev Initiates a flash loan to swap collateral assets
   * @param fromCollateralAsset Address of the collateral asset to swap from
   * @param toCollateralAsset Address of the collateral asset to swap to
   * @param fromCollateralAmount Amount of from collateral to swap
   * @param rateMode Rate mode for the position (1 for stable, 2 for variable)
   * @param gluexData Data for Gluex Router
   * @param permitSignature Permit signature for hyToken transfer
   */
  function flashLoanAndSwap(
    IERC20 fromCollateralAsset,
    IERC20 toCollateralAsset,
    uint256 fromCollateralAmount,
    uint256 rateMode,
    bytes calldata gluexData,
    PermitSignature calldata permitSignature
  ) external nonReentrant {
    FlashLoanData memory flashData = FlashLoanData({
      fromCollateralAsset: fromCollateralAsset,
      toCollateralAsset: toCollateralAsset,
      fromCollateralAmount: fromCollateralAmount,
      rateMode: rateMode,
      gluexData: gluexData,
      permitSignature: permitSignature,
      user: msg.sender
    });

    // Flash loan the from collateral asset
    POOL.flashLoanSimple(
      address(this),
      address(fromCollateralAsset),
      fromCollateralAmount,
      abi.encode(flashData),
      0
    );
  }

  /**
   * @dev Flash loan callback function - executes the swap operation
   * @param initiator The address of the flashloan initiator
   * @param token The address of the flash-borrowed asset (from collateral asset)
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

    // Deposit the flash loaned amount into the pool on behalf of the user first
    IERC20(token).safeApprove(address(POOL), amount);
    POOL.deposit(address(token), amount, flashData.user, 0);
    IERC20(token).safeApprove(address(POOL), 0);

    // Pull hyTokens (from collateral) from user
    _pullHyTokenAndWithdraw(address(flashData.fromCollateralAsset), flashData.user, flashData.fromCollateralAmount, flashData.permitSignature);

    // Calculate total amount needed to repay flash loan
    uint256 totalNeededForFlashLoan = amount.add(fee);

    // Swap from collateral to to collateral
    (uint256 amountSold, uint256 amountBought) = _buyOnGluex(
      flashData.gluexData,
      flashData.fromCollateralAsset,
      flashData.toCollateralAsset
    );

    // Verify we sold enough to cover the flash loan
    require(amountSold >= totalNeededForFlashLoan, "INSUFFICIENT_COLLATERAL_SOLD");

    // Approve flash loan repayment
    IERC20(token).safeApprove(address(POOL), totalNeededForFlashLoan);

    // Deposit the new collateral to the pool for the user
    IERC20(flashData.toCollateralAsset).safeApprove(address(POOL), amountBought);
    POOL.deposit(address(flashData.toCollateralAsset), amountBought, flashData.user, 0);
    IERC20(flashData.toCollateralAsset).safeApprove(address(POOL), 0);

    // Transfer excess from collateral back to the user
    uint256 fromCollateralExcess = flashData.fromCollateralAmount - amountSold;
    if (fromCollateralExcess > 0) {
      // Deposit excess from collateral back to the pool for the user
      IERC20(flashData.fromCollateralAsset).safeApprove(address(POOL), fromCollateralExcess);
      POOL.deposit(address(flashData.fromCollateralAsset), fromCollateralExcess, flashData.user, 0);
      IERC20(flashData.fromCollateralAsset).safeApprove(address(POOL), 0);
    }

    return CALLBACK_SUCCESS;
  }

  /**
   * @dev Swaps the user's collateral for another collateral asset without using flash loans.
   * This method can be used when the temporary transfer of the collateral asset to this
   * contract does not affect the user position.
   * The user should give this contract allowance to pull the hyTokens in order to withdraw the underlying asset
   * @param fromCollateralAsset Address of the collateral asset to swap from
   * @param toCollateralAsset Address of the collateral asset to swap to
   * @param fromCollateralAmount Amount of the from collateral to be swapped
   * @param gluexData Data for Gluex Router
   * @param permitSignature struct containing the permit signature
   */
  function swapCollateral(
    IERC20 fromCollateralAsset,
    IERC20 toCollateralAsset,
    uint256 fromCollateralAmount,
    bytes calldata gluexData,
    PermitSignature calldata permitSignature
  ) external nonReentrant {
    // Pull hyTokens from user
    _pullHyTokenAndWithdraw(address(fromCollateralAsset), msg.sender, fromCollateralAmount, permitSignature);
    
    // Swap from collateral to to collateral
    (uint256 amountSold, uint256 amountBought) = _buyOnGluex(
      gluexData,
      fromCollateralAsset,
      toCollateralAsset
    );

    // Deposit the new collateral to the pool for the user
    IERC20(toCollateralAsset).safeApprove(address(POOL), amountBought);
    POOL.deposit(address(toCollateralAsset), amountBought, msg.sender, 0);
    IERC20(toCollateralAsset).safeApprove(address(POOL), 0);

    // Transfer excess from collateral back to the user
    uint256 fromCollateralExcess = fromCollateralAmount - amountSold;
    if (fromCollateralExcess > 0) {
      // Deposit excess from collateral back to the pool for the user
      IERC20(fromCollateralAsset).safeApprove(address(POOL), fromCollateralExcess);
      POOL.deposit(address(fromCollateralAsset), fromCollateralExcess, msg.sender, 0);
      IERC20(fromCollateralAsset).safeApprove(address(POOL), 0);
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
} 