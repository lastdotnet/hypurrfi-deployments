// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeERC20} from 'lib/solidity-utils/src/contracts/oz-common/SafeERC20.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {PercentageMath} from '@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IERC20} from 'lib/solidity-utils/src/contracts/oz-common/interfaces/IERC20.sol';
import {BaseGluexAdapter} from './BaseGluexAdapter.sol';
import {IERC20WithPermit} from 'aave-v3-core/contracts/interfaces/IERC20WithPermit.sol';
import {IPriceOracleGetter} from 'aave-v3-core/contracts/interfaces/IPriceOracleGetter.sol';
import {DataTypes} from 'aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol';
import {GPv2SafeERC20} from 'aave-v3-core/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {SafeMath} from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {Ownable} from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/Ownable.sol';
import {IERC20Detailed} from 'aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';

/**
 * @title BaseGluexAdapter
 * @notice Utility functions for adapters using Gluex
 * @author Jason Raymond Bell
 */
abstract contract BaseGluexAdapter is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using GPv2SafeERC20 for IERC20;
  using GPv2SafeERC20 for IERC20WithPermit;

  struct PermitSignature {
    uint256 amount;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  // Max slippage percent allowed
  uint256 public constant MAX_SLIPPAGE_PERCENT = 3000; // 30%

  IPriceOracleGetter public immutable ORACLE;
  IPool public immutable POOL;

  event Swapped(
    address indexed fromAsset,
    address indexed toAsset,
    uint256 fromAmount,
    uint256 receivedAmount
  );
  event Bought(
    address indexed fromAsset,
    address indexed toAsset,
    uint256 amountSold,
    uint256 receivedAmount
  );

  constructor(
    IPoolAddressesProvider addressesProvider
  ) {
    ORACLE = IPriceOracleGetter(addressesProvider.getPriceOracle());
    POOL = IPool(addressesProvider.getPool());
  }

  /**
   * @dev Get the price of the asset from the oracle denominated in eth
   * @param asset address
   * @return eth price for the asset
   */
  function _getPrice(address asset) internal view returns (uint256) {
    return ORACLE.getAssetPrice(asset);
  }

  /**
   * @dev Get the decimals of an asset
   * @return number of decimals of the asset
   */
  function _getDecimals(IERC20 asset) internal view returns (uint8) {
    uint8 decimals = IERC20Detailed(address(asset)).decimals();
    // Ensure 10**decimals won't overflow a uint256
    require(decimals <= 77, 'TOO_MANY_DECIMALS_ON_TOKEN');
    return decimals;
  }

  /**
   * @dev Get the hyToken associated to the asset
   * @return address of the hyToken
   */
  function _getReserveData(
    address asset
  ) internal view returns (DataTypes.ReserveData memory) {
    return POOL.getReserveData(asset);
  }

  function _pullHyTokenAndWithdraw(
    address reserve,
    address user,
    uint256 amount,
    PermitSignature memory permitSignature
  ) internal virtual {
    IERC20WithPermit reserveHyToken = IERC20WithPermit(
      _getReserveData(address(reserve)).aTokenAddress
    );
    _pullHyTokenAndWithdraw(reserve, reserveHyToken, user, amount, permitSignature);
  }

  /**
   * @dev Pull the hyTokens from the user
   * @param reserve address of the asset
   * @param reserveHyToken address of the hyToken of the reserve
   * @param user address
   * @param amount of tokens to be transferred to the contract
   * @param permitSignature struct containing the permit signature
   */
  function _pullHyTokenAndWithdraw(
    address reserve,
    IERC20WithPermit reserveHyToken,
    address user,
    uint256 amount,
    PermitSignature memory permitSignature
  ) internal virtual {
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

    // transfer from user to adapter
    reserveHyToken.safeTransferFrom(user, address(this), amount);

    // withdraw reserve
    require(POOL.withdraw(reserve, amount, address(this)) == amount, 'UNEXPECTED_AMOUNT_WITHDRAWN');
  }

  /**
   * @dev Emergency rescue for token stucked on this contract, as failsafe mechanism
   * - Funds should never remain in this contract more time than during transactions
   * - Only callable by the owner
   */
  function rescueTokens(IERC20 token) external onlyOwner {
    token.safeTransfer(owner(), token.balanceOf(address(this)));
  }
}