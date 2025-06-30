// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import {GluexRepayAdapter} from "../src/periphery/contracts/adapters/gluex/GluexRepayAdapter.sol";
import {GluexCollateralSwapAdapter} from "../src/periphery/contracts/adapters/gluex/GluexCollateralSwapAdapter.sol";
import {GluexDebtSwapAdapter} from "../src/periphery/contracts/adapters/gluex/GluexDebtSwapAdapter.sol";
import {IPoolAddressesProvider} from "lib/aave-v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {DeployUtils} from "src/deployments/utils/DeployUtils.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title DeployGluexAdapters
 * @notice Deploy script for all Gluex adapters
 * @author Last Labs
 **/
contract DeployGluexAdapters is Script {
    using stdJson for string;
    using DeployUtils for string;

    string deployedContracts;
    string instanceId;

    IPoolAddressesProvider poolAddressesProvider;
    GluexRepayAdapter gluexRepayAdapter;
    GluexCollateralSwapAdapter gluexCollateralSwapAdapter;
    GluexDebtSwapAdapter gluexDebtSwapAdapter;

    address admin;
    address deployer;
    address gluexRouter;
    string config;

  function run() external {
    console2.log("GluexRepayAdapter Deployment");
    console2.log("sender", msg.sender);
    console2.log("chainid", block.chainid);

    instanceId = vm.envOr("INSTANCE_ID", string("primary"));
    vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

    config = DeployUtils.loadConfig(instanceId);

    admin = config.readAddress(".admin");
    deployer = msg.sender;
    gluexRouter = config.readAddress(".gluexRouter");

    deployedContracts = DeployUtils.readOutput(instanceId);

    poolAddressesProvider = IPoolAddressesProvider(deployedContracts.readAddress(".poolAddressesProvider"));

    console2.log("Pool Addresses Provider:", address(poolAddressesProvider));
    console2.log("Gluex Router:", gluexRouter);
    console2.log("Admin:", admin);

    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    // Deploy GluexRepayAdapter
    gluexRepayAdapter = new GluexRepayAdapter(
      IPoolAddressesProvider(poolAddressesProvider),
      gluexRouter,
      admin
    );

    // Deploy GluexCollateralSwapAdapter
    gluexCollateralSwapAdapter = new GluexCollateralSwapAdapter(
      IPoolAddressesProvider(poolAddressesProvider),
      gluexRouter,
      admin
    );

    // Deploy GluexDebtSwapAdapter
    gluexDebtSwapAdapter = new GluexDebtSwapAdapter(
      IPoolAddressesProvider(poolAddressesProvider),
      gluexRouter,
      admin
    );

    vm.stopBroadcast();

    DeployUtils.exportContract(
      string(abi.encodePacked(instanceId, "-gluex-adapters")),
      "gluexRepayAdapter",
      address(gluexRepayAdapter)
    );
    DeployUtils.exportContract(
      string(abi.encodePacked(instanceId, "-gluex-adapters")),
      "gluexCollateralSwapAdapter",
      address(gluexCollateralSwapAdapter)
    );
    DeployUtils.exportContract(
      string(abi.encodePacked(instanceId, "-gluex-adapters")),
      "gluexDebtSwapAdapter",
      address(gluexDebtSwapAdapter)
    );

    console2.log('=== Gluex Adapters Deployment Results ===');
    console2.log('GluexRepayAdapter deployed at:', address(gluexRepayAdapter));
    console2.log('GluexCollateralSwapAdapter deployed at:', address(gluexCollateralSwapAdapter));
    console2.log('GluexDebtSwapAdapter deployed at:', address(gluexDebtSwapAdapter));
    console2.log('Pool Addresses Provider:', address(poolAddressesProvider));
    console2.log('Gluex Router:', gluexRouter);
    console2.log('Admin:', admin);
  }
} 