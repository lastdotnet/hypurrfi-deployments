// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "solidity-utils/contracts/oz-common/interfaces/IERC20.sol";
import {IERC20Metadata} from "solidity-utils/contracts/oz-common/interfaces/IERC20Metadata.sol";
import {Ownable} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/Ownable.sol";
import {SafeERC20} from 'solidity-utils/contracts/oz-common/SafeERC20.sol';
import {IWrappedHypeGateway} from 'src/periphery/contracts/misc/interfaces/IWrappedHypeGateway.sol';
import {IPoolConfigurator} from "aave-v3-core/contracts/interfaces/IPoolConfigurator.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {ConfiguratorInputTypes} from "@aave/core-v3/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol";
import {IAaveOracle} from "aave-v3-core/contracts/interfaces/IAaveOracle.sol";
/**
 * @title ReserveInitializer
 * @notice Contract to initialize reserves and handle token transfers, including HYPE to WHYPE wrapping
 */
contract ReserveInitializer is Ownable {
    using SafeERC20 for IERC20;

    IWrappedHypeGateway public immutable WRAPPED_TOKEN_GATEWAY;
    IPoolConfigurator public immutable POOL_CONFIGURATOR;
    IPool public immutable POOL;
    IAaveOracle public immutable ORACLE;
    struct ReserveConfig {
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 supplyCap;
        uint256 borrowCap;
        uint256 debtCeiling;
        address oracle;
        bool isCollateralEnabled;
    }

    constructor(
        address wrappedTokenGateway,
        address poolConfigurator,
        address pool,
        address oracle
    ) Ownable() {
        WRAPPED_TOKEN_GATEWAY = IWrappedHypeGateway(wrappedTokenGateway);
        POOL_CONFIGURATOR = IPoolConfigurator(poolConfigurator);
        POOL = IPool(pool);
        ORACLE = IAaveOracle(oracle);
    }

    /**
     * @notice Initializes reserves by transferring tokens to the specified address
     * @param inputs The reserve configuration inputs
     * @param initialAmounts Initial amounts to supply to the pool
     */
    function batchInitReserves(
        ConfiguratorInputTypes.InitReserveInput[] memory inputs,
        uint256[] memory initialAmounts,
        ReserveConfig[] memory reserveConfigs
    ) external payable onlyOwner {


        // Step 1: Set oracle Feeds for anything that is being initialized
        address[] memory assets = new address[](inputs.length);
        address[] memory oracles = new address[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            assets[i] = inputs[i].underlyingAsset;
            oracles[i] = reserveConfigs[i].oracle;
        }
        ORACLE.setAssetSources(assets, oracles);
        // Initialize Reserves
        IPoolConfigurator(POOL_CONFIGURATOR).initReserves(inputs);

        // Step 3: Configure Reserves
        for (uint256 i = 0; i < inputs.length; i++) {
            ReserveConfig memory config = reserveConfigs[i];
            address underlyingAsset = inputs[i].underlyingAsset;
            uint256 initialAmount = initialAmounts[i];

            POOL_CONFIGURATOR.setReserveStableRateBorrowing(underlyingAsset, false);
            
            if (config.isCollateralEnabled) {
                POOL_CONFIGURATOR.configureReserveAsCollateral(underlyingAsset, config.ltv, config.liquidationThreshold, config.liquidationBonus);
            }
            
            POOL_CONFIGURATOR.setReserveBorrowing(underlyingAsset, true);
            
            if (config.debtCeiling > 0) {
                POOL_CONFIGURATOR.setDebtCeiling(underlyingAsset, config.debtCeiling);
            }
            if (config.supplyCap > 0) {
                POOL_CONFIGURATOR.setSupplyCap(underlyingAsset, config.supplyCap);
            }
            if (config.borrowCap > 0) {
                POOL_CONFIGURATOR.setBorrowCap(underlyingAsset, config.borrowCap);
            }


            POOL_CONFIGURATOR.setReserveFlashLoaning(underlyingAsset, true);

            require(initialAmount > 0, "reserve cannot be initialized with zero supply");

            if (underlyingAsset == address(WRAPPED_TOKEN_GATEWAY.getWHYPEAddress()) && msg.value > 0) {
                // For HYPE tokens, wrap them to WHYPE first
                WRAPPED_TOKEN_GATEWAY.depositHYPE{value: msg.value}(address(POOL), msg.sender, 0);
            } else {
                require(IERC20(underlyingAsset).balanceOf(address(this)) >= initialAmount, string(abi.encodePacked("Insufficient balance of ", IERC20Metadata(underlyingAsset).symbol())));
                // Approve pool to spend tokens
                IERC20(underlyingAsset).safeIncreaseAllowance(address(POOL), initialAmount);
                // Supply to pool
                POOL.supply(underlyingAsset, initialAmount, address(0), 0);
            }
        }
    }
}
