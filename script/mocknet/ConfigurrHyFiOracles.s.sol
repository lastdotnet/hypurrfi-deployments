// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";

import {HyperMocknetReservesConfigs} from "src/deployments/configs/HyperMocknetReservesConfigs.sol";
import {DeployUtils} from "src/deployments/utils/DeployUtils.sol";
import {MockAggregator} from "aave-v3-core/contracts/mocks/oracle/CLAggregators/MockAggregator.sol";

contract ConfigurrHyFiReserves is HyperMocknetReservesConfigs, Script {
    using stdJson for string;

    string instanceId;
    uint256 instanceIdBlock = 0;
    string rpcUrl;
    uint256 forkBlock;
    uint256 initialReserveCount;

    string config;
    string deployedContracts;

    function run() external {
        instanceId = vm.envOr("INSTANCE_ID", string("primary"));
        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        config = DeployUtils.readInput(instanceId);
        if (instanceIdBlock > 0) {
            deployedContracts = DeployUtils.readOutput(instanceId, instanceIdBlock);
        } else {
            deployedContracts = DeployUtils.readOutput(instanceId);
        }

        _setDeployRegistry(deployedContracts);

        address[] memory tokens;
        address[] memory oracles;

        console.log("HypurrFi Mocknet Reserve Config");
        console.log("sender", msg.sender);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        tokens = _fetchMocknetTokens(config);

        oracles = _fetchMocknetOracles(config);

        oracles[0] = address(new MockAggregator(1e8));

        // set oracles
        _getAaveOracle().setAssetSources(tokens, oracles);

        vm.stopBroadcast();
    }
}
