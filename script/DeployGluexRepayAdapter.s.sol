// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {DeployUtils} from "src/deployments/utils/DeployUtils.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";

import {GluexRepayAdapter} from "src/periphery/contracts/adapters/gluex/GluexRepayAdapter.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesProvider.sol";

contract DeployGluexRepayAdapter is Script {
    using stdJson for string;
    using DeployUtils for string;

    string deployedContracts;
    string instanceId;

    IPoolAddressesProvider poolAddressesProvider;
    GluexRepayAdapter gluexRepayAdapter;

    address admin;
    address deployer;
    address gluexRouter;
    string config;

    function run() external {
        console.log("GluexRepayAdapter Deployment");
        console.log("sender", msg.sender);
        console.log("chainid", block.chainid);

        instanceId = vm.envOr("INSTANCE_ID", string("primary"));
        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        config = DeployUtils.loadConfig(instanceId);

        admin = config.readAddress(".admin");
        deployer = msg.sender;
        gluexRouter = config.readAddress(".gluexRouter");

        deployedContracts = DeployUtils.readOutput(instanceId);

        poolAddressesProvider = IPoolAddressesProvider(deployedContracts.readAddress(".poolAddressesProvider"));

        console.log("Pool Addresses Provider:", address(poolAddressesProvider));
        console.log("Gluex Router:", gluexRouter);
        console.log("Admin:", admin);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        gluexRepayAdapter = new GluexRepayAdapter(
            poolAddressesProvider,
            gluexRouter,
            admin
        );

        vm.stopBroadcast();

        DeployUtils.exportContract(
            string(abi.encodePacked(instanceId, "-gluexRepayAdapter")), 
            "gluexRepayAdapter", 
            address(gluexRepayAdapter)
        );

        console.log("GluexRepayAdapter deployed at:", address(gluexRepayAdapter));
    }
} 