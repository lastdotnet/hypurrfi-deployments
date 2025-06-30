// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from 'lib/solidity-utils/src/contracts/oz-common/SafeERC20.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';

/**
 * @title BorrowAllowanceLib
 * @notice Library for borrow allowance utility functions
 * @author Last Labs
 **/
library BorrowAllowanceLib {
  /**
   * @dev Get the current borrow allowance for a user on a specific asset (variable debt only)
   * @param pool The Aave pool contract
   * @param asset Address of the asset to check borrow allowance for
   * @param user Address of the user
   * @return Current borrow allowance amount
   */
  function getBorrowAllowance(
    IPool pool,
    address asset,
    address user
  ) internal view returns (uint256) {
    DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
    address variableDebtToken = reserveData.variableDebtTokenAddress;
    
    // Call allowance on the variable debt token
    return IERC20(variableDebtToken).allowance(user, address(this));
  }

  /**
   * @dev Check if user has sufficient borrow allowance for a specific amount (variable debt only)
   * @param pool The Aave pool contract
   * @param asset Address of the asset to check
   * @param user Address of the user
   * @param amount Amount to check allowance for
   * @return True if user has sufficient borrow allowance
   */
  function hasBorrowAllowance(
    IPool pool,
    address asset,
    address user,
    uint256 amount
  ) internal view returns (bool) {
    uint256 allowance = getBorrowAllowance(pool, asset, user);
    return allowance >= amount;
  }

  /**
   * @dev Get borrow allowance for multiple assets (variable debt only)
   * @param pool The Aave pool contract
   * @param assets Array of asset addresses to check
   * @param user Address of the user
   * @return Array of borrow allowance amounts
   */
  function getBorrowAllowances(
    IPool pool,
    address[] calldata assets,
    address user
  ) internal view returns (uint256[] memory) {
    uint256[] memory allowances = new uint256[](assets.length);
    
    for (uint256 i = 0; i < assets.length; i++) {
      allowances[i] = getBorrowAllowance(pool, assets[i], user);
    }
    
    return allowances;
  }

  /**
   * @dev Get the variable debt token address for a given asset
   * @param pool The Aave pool contract
   * @param asset Address of the asset
   * @return Variable debt token address
   */
  function getVariableDebtToken(IPool pool, address asset) internal view returns (address) {
    DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);
    return reserveData.variableDebtTokenAddress;
  }

  /**
   * @dev Get the current variable debt balance for a user on a specific asset
   * @param pool The Aave pool contract
   * @param asset Address of the asset
   * @param user Address of the user
   * @return Current variable debt balance
   */
  function getVariableDebtBalance(
    IPool pool,
    address asset,
    address user
  ) internal view returns (uint256) {
    address variableDebtToken = getVariableDebtToken(pool, asset);
    return IERC20(variableDebtToken).balanceOf(user);
  }
} 