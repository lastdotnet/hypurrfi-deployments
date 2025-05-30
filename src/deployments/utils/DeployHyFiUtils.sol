// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0;

import {stdJson} from "forge-std/StdJson.sol";
import {DeployUtils} from "src/deployments/utils/DeployUtils.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20Metadata} from "src/contracts/dependencies/openzeppelin/interfaces/IERC20Metadata.sol";

import {InitializableAdminUpgradeabilityProxy} from
    "aave-v3-core/contracts/dependencies/openzeppelin/upgradeability/InitializableAdminUpgradeabilityProxy.sol";

import {PoolAddressesProviderRegistry} from
    "aave-v3-core/contracts/protocol/configuration/PoolAddressesProviderRegistry.sol";
import {PoolAddressesProvider} from "aave-v3-core/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {HyFiProtocolDataProvider} from "src/core/contracts/misc/HyFiProtocolDataProvider.sol";
import {PoolConfigurator} from "aave-v3-core/contracts/protocol/pool/PoolConfigurator.sol";
import {Pool} from "aave-v3-core/contracts/protocol/pool/Pool.sol";
import {ACLManager} from "aave-v3-core/contracts/protocol/configuration/ACLManager.sol";
import {HyFiOracle} from "src/core/contracts/misc/HyFiOracle.sol";

import {HyToken} from "src/core/contracts/protocol/tokenization/HyToken.sol";
import {DisabledStableDebtToken} from "src/core/contracts/protocol/tokenization/DisabledStableDebtToken.sol";
import {VariableDebtToken} from "aave-v3-core/contracts/protocol/tokenization/VariableDebtToken.sol";

import {IHyFiIncentivesController} from "src/core/contracts/interfaces/IHyFiIncentivesController.sol";

import {Collector} from "aave-v3-periphery/treasury/Collector.sol";
import {CollectorController} from "aave-v3-periphery/treasury/CollectorController.sol";
import {RewardsController} from "aave-v3-periphery/rewards/RewardsController.sol";
import {EmissionManager} from "aave-v3-periphery/rewards/EmissionManager.sol";

import {UiPoolDataProviderV3} from "aave-v3-periphery/misc/UiPoolDataProviderV3.sol";
import {UiIncentiveDataProviderV3} from "aave-v3-periphery/misc/UiIncentiveDataProviderV3.sol";
import {WrappedHypeGateway} from "src/periphery/contracts/misc/WrappedHypeGateway.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {WalletBalanceProvider} from "aave-v3-periphery/misc/WalletBalanceProvider.sol";
import {IEACAggregatorProxy} from "aave-v3-periphery/misc/interfaces/IEACAggregatorProxy.sol";
import {DefaultReserveInterestRateStrategy} from
    "aave-v3-core/contracts/protocol/pool/DefaultReserveInterestRateStrategy.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReserveInitializer} from "src/periphery/contracts/misc/ReserveInitializer.sol";
import {IACLManager} from "aave-v3-core/contracts/interfaces/IACLManager.sol";
abstract contract DeployHyFiUtils {

    using stdJson for string;
    using DeployUtils for string;

    Vm constant vm2 = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string config;
    string instanceId;
    string deployedContracts;
    address admin;
    address deployer;

    PoolAddressesProviderRegistry registry;
    PoolAddressesProvider poolAddressesProvider;
    HyFiProtocolDataProvider protocolDataProvider;
    PoolConfigurator poolConfigurator;
    PoolConfigurator poolConfiguratorImpl;
    Pool pool;
    Pool poolImpl;
    ACLManager aclManager;
    HyFiOracle hyFiOracle;

    HyToken hyTokenImpl;
    DisabledStableDebtToken disabledStableDebtTokenImpl;
    VariableDebtToken variableDebtTokenImpl;

    Collector treasury;
    address treasuryImpl;
    CollectorController treasuryController;
    RewardsController incentivesImpl;
    EmissionManager emissionManager;
    Collector collectorImpl;

    UiPoolDataProviderV3 uiPoolDataProvider;
    UiIncentiveDataProviderV3 uiIncentiveDataProvider;
    WrappedHypeGateway wrappedHypeGateway;
    WalletBalanceProvider walletBalanceProvider;

    InitializableAdminUpgradeabilityProxy incentivesProxy;
    RewardsController rewardsController;
    IEACAggregatorProxy proxy;

    DefaultReserveInterestRateStrategy interestRateStrategy;

    ReserveInitializer reserveInitializer;
    
    uint256 constant RAY = 10 ** 27;

    function _deployRegistry(bool) internal {
        // switchBigBlocks(liveEnv, false);
        registry = new PoolAddressesProviderRegistry(deployer);
    }

    function _deployPoolAddressesProvider(bool) internal {
        poolAddressesProvider = new PoolAddressesProvider(config.readString(".marketId"), deployer);
    }

    function _deployHyFi(bool) internal {
        // 1. Deploy and configure registry and addresses provider
        registry = new PoolAddressesProviderRegistry(deployer);
        poolAddressesProvider = new PoolAddressesProvider(config.readString(".marketId"), deployer);
        poolAddressesProvider.setACLAdmin(deployer);

        // 2. Deploy data provider and pool configurator, initialize pool configurator
        protocolDataProvider = new HyFiProtocolDataProvider(poolAddressesProvider);
        poolConfiguratorImpl = new PoolConfigurator();
        poolConfiguratorImpl.initialize(poolAddressesProvider);

        // 3. Deploy pool implementation and initialize
        poolImpl = new Pool(poolAddressesProvider);
        poolImpl.initialize(poolAddressesProvider);

        // 4. Deploy and configure ACL manager
        aclManager = new ACLManager(poolAddressesProvider);
        aclManager.addPoolAdmin(deployer);

        // 5. Additional configuration for registry and pool address provider

        registry.registerAddressesProvider(address(poolAddressesProvider), 1);

        poolAddressesProvider.setPoolDataProvider(address(protocolDataProvider));
        poolAddressesProvider.setPoolImpl(address(poolImpl));

        // 6. Get pool instance

        pool = Pool(poolAddressesProvider.getPool());

        // 7. Set the Pool Configurator implementation and ACL manager and get the pool configurator instance

        poolAddressesProvider.setPoolConfiguratorImpl(address(poolConfiguratorImpl));
        poolConfigurator = PoolConfigurator(poolAddressesProvider.getPoolConfigurator());
        poolAddressesProvider.setACLManager(address(aclManager));

        // 8. Deploy and initialize hyToken instance

        hyTokenImpl = new HyToken(pool);
        hyTokenImpl.initialize(
            pool, address(0), address(0), IHyFiIncentivesController(address(0)), 0, "HY_TOKEN_IMPL", "HY_TOKEN_IMPL", ""
        );

        // 9. Deploy and initialize disabledStableDebtToken instance

        disabledStableDebtTokenImpl = new DisabledStableDebtToken(pool);
        disabledStableDebtTokenImpl.initialize(
            pool,
            address(0),
            IHyFiIncentivesController(address(0)),
            0,
            "STABLE_DEBT_TOKEN_IMPL",
            "STABLE_DEBT_TOKEN_IMPL",
            ""
        );

        // 10. Deploy and initialize variableDebtToken instance

        variableDebtTokenImpl = new VariableDebtToken(pool);
        variableDebtTokenImpl.initialize(
            pool,
            address(0),
            IHyFiIncentivesController(address(0)),
            0,
            "VARIABLE_DEBT_TOKEN_IMPL",
            "VARIABLE_DEBT_TOKEN_IMPL",
            ""
        );

        // 11. Deploy Collector, CollectorController and treasury contracts.

        treasuryController = new CollectorController(admin);
        collectorImpl = new Collector();

        collectorImpl.initialize(address(0));

        (treasury, treasuryImpl) = createCollector(admin);

        // 12. Deploy initialize and configure rewards contracts.

        // incentivesProxy = new InitializableAdminUpgradeabilityProxy();
        // switchBigBlocks(liveEnv, true);
        // incentivesImpl = RewardsController(address(incentivesProxy));
        // switchBigBlocks(liveEnv, true);
        // emissionManager = new EmissionManager(deployer);
        // rewardsController = new RewardsController(address(emissionManager));

        // rewardsController.initialize(address(0));
        // incentivesProxy.initialize(
        //     address(rewardsController), admin, abi.encodeWithSignature("initialize(address)", address(emissionManager))
        // );
        // emissionManager.setRewardsController(address(incentivesImpl));

        // 13. Update flash loan premium to zero.

        poolConfigurator.updateFlashloanPremiumTotal(0); // Flash loans are free

        // 14. Deploy data provider contracts.

        proxy = IEACAggregatorProxy(config.readAddress(".nativeTokenOracle"));
        uiPoolDataProvider = new UiPoolDataProviderV3(proxy, proxy);
        uiIncentiveDataProvider = new UiIncentiveDataProviderV3();
        wrappedHypeGateway = new WrappedHypeGateway(config.readAddress(".nativeToken"), admin, IPool(address(pool)));
        walletBalanceProvider = new WalletBalanceProvider();

        // 15. Set up oracle.

        address[] memory assets;
        address[] memory oracles;
        hyFiOracle = new HyFiOracle(
            poolAddressesProvider,
            assets,
            oracles,
            address(0), // no fallback oracle initially
            address(0), // USD
            1e8
        );
        poolAddressesProvider.setPriceOracle(address(hyFiOracle));

        // 16. Transfer all ownership from deployer to admin

        aclManager.addEmergencyAdmin(admin);
        aclManager.addPoolAdmin(admin);
        if (admin != deployer) {
            aclManager.removePoolAdmin(deployer);
        }
        aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), admin);
        if (admin != deployer) {
            aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);
        }

        poolAddressesProvider.setACLAdmin(admin);
        poolAddressesProvider.transferOwnership(admin);

        registry.transferOwnership(admin);
        // emissionManager.transferOwnership(admin);

        // 17. Deploy interest rate strategy.

        interestRateStrategy = new DefaultReserveInterestRateStrategy(
            IPoolAddressesProvider(address(poolAddressesProvider)),
            80_00 * (RAY / 100_00), // optimal usage ratio: 80%
            0, // base variable borrow rate: 0%
            4_00 * (RAY / 100_00), // variable rate slope1: 4%
            75_00 * (RAY / 100_00), // variable rate slope2: 75%
            2_00 * (RAY / 100_00), // stable rate slope1: 2%
            75_00 * (RAY / 100_00), // stable rate slope2: 75%
            1_00 * (RAY / 100_00), // base stable borrow rate: 1%
            80 * (RAY / 100_00), // stableRateExcessOffset: 0.8%
            20_00 * (RAY / 100_00) // optimalStableToTotalDebtRatio: 20%
        );
    }

    function createCollector(address _admin) internal returns (Collector collector, address impl) {
        InitializableAdminUpgradeabilityProxy collectorProxy = new InitializableAdminUpgradeabilityProxy();
        collector = Collector(address(collectorProxy));
        impl = address(collectorImpl);
        collectorProxy.initialize(
            address(collectorImpl), _admin, abi.encodeWithSignature("initialize(address)", address(treasuryController))
        );
    }

    function createUiPoolDataProvider() internal {
        proxy = IEACAggregatorProxy(config.readAddress(".nativeTokenOracle"));
        console.log("proxy: ", address(proxy));
        uiPoolDataProvider = new UiPoolDataProviderV3(proxy, proxy);
    }

    function switchBigBlocks(bool liveEnv, bool usingBigBlocks) internal {
        if (liveEnv) {
            vm2.stopBroadcast();
            string[] memory command = new string[](3);
            command[0] = "python3";
            command[1] = "big_blocks.py";
            command[2] = usingBigBlocks ? "true" : "false";
            vm2.ffi(command);
            vm2.startBroadcast(vm2.envUint("PRIVATE_KEY"));
        }
    }

    function _setContractAddresses() internal {
        aclManager = ACLManager(deployedContracts.readAddress(".aclManager"));
        registry = PoolAddressesProviderRegistry(deployedContracts.readAddress(".poolAddressesProviderRegistry"));
        poolAddressesProvider = PoolAddressesProvider(deployedContracts.readAddress(".poolAddressesProvider"));
        treasury = Collector(deployedContracts.readAddress(".treasury"));
        wrappedHypeGateway = WrappedHypeGateway(payable(deployedContracts.readAddress(".wrappedHypeGateway")));
        treasuryController = CollectorController(deployedContracts.readAddress(".treasuryController"));
        reserveInitializer = ReserveInitializer(deployedContracts.readAddress(".reserveInitializer"));
    }

    function _transferOwnership() internal {
        aclManager.addEmergencyAdmin(admin);
        aclManager.addPoolAdmin(admin);
        if (admin != deployer) {
            aclManager.removePoolAdmin(deployer);
            aclManager.removeEmergencyAdmin(deployer);
        }
        aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), admin);
        if (admin != deployer) {
            aclManager.revokeRole(aclManager.DEFAULT_ADMIN_ROLE(), deployer);
        }

        poolAddressesProvider.setACLAdmin(admin);
        poolAddressesProvider.transferOwnership(admin);

        registry.transferOwnership(admin);

        wrappedHypeGateway.transferOwnership(admin);

        InitializableAdminUpgradeabilityProxy(payable(address(treasury))).changeAdmin(admin);
        
        treasuryController.transferOwnership(admin);
        reserveInitializer.transferOwnership(admin);
    }

    function _addPoolAdmin(address aclManager, address newAdmin) internal {
        IACLManager(aclManager).addPoolAdmin(newAdmin);
    }

    function _removePoolAdmin(address aclManager, address oldAdmin) internal {
        IACLManager(aclManager).removePoolAdmin(oldAdmin);
    }
}
