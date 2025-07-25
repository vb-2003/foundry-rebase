// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

contract CrossChainTest is Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    uint256 SEND_VALUE = 1e5;
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;

    uint256 sepoliaFork;
    uint256 arbSepoliaFork;
    
    RebaseToken sepoliaToken;
    RebaseToken arbSepoliaToken;

    RebaseTokenPool sepoliaPool;
    RebaseTokenPool arbSepoliaPool;

    TokenAdminRegistry tokenAdminRegistrySepolia;
    TokenAdminRegistry tokenAdminRegistryarbSepolia;

    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    Vault vault;

    function setUp() public {
        address[] memory allowList = new address[](0);

        sepoliaFork = vm.createSelectFork("sepolia-eth");
        arbSepoliaFork = vm.createFork("arb-sepolia");

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        vm.startPrank(owner);

        sepoliaToken = new RebaseToken();
        sepoliaPool = new RebaseTokenPool(IERC20(address(sepoliaToken)), allowList, sepoliaNetworkDetails.rmnProxyAddress, sepoliaNetworkDetails.routerAddress);
        
        vault = new Vault(IRebaseToken(address(sepoliaToken)));
        vm.deal(address(vault), 1e18);
        sepoliaToken.grantMintAndBurnRole(address(vault));
        sepoliaToken.grantMintAndBurnRole(address(sepoliaPool));

        RegistryModuleOwnerCustom(sepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(address(sepoliaToken));
        TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(sepoliaToken));
        TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(address(sepoliaToken), address(sepoliaPool));
        
        vm.stopPrank();

        vm.selectFork(arbSepoliaFork);
        vm.startPrank(owner);
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        arbSepoliaToken = new RebaseToken();
        arbSepoliaPool = new RebaseTokenPool(IERC20(address(arbSepoliaToken)), allowList, arbSepoliaNetworkDetails.rmnProxyAddress, arbSepoliaNetworkDetails.routerAddress);

        arbSepoliaToken.grantMintAndBurnRole(address(arbSepoliaPool));
        RegistryModuleOwnerCustom(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(address(arbSepoliaToken));
        TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(arbSepoliaToken));
        TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(address(arbSepoliaToken), address(arbSepoliaPool));

        vm.stopPrank();
    }

    function configureTokenPool(uint256 fork, address localPool, uint64 remoteChainSelector, address remotePool, address remoteTokenAddress) public {
        vm.selectFork(fork);
        
        vm.startPrank(owner);
        TokenPool.ChainUpdate[] memory chainsToAdd = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(address(remotePool));

        chainsToAdd[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteTokenAddress),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            })
        });
        
        TokenPool(localPool).applyChainUpdates(new uint64[](0), chainsToAdd);
        vm.stopPrank();
    }

    function bridgeTokens(uint256 amountToBridge, uint256 localFork, uint256 remoteFork, Register.NetworkDetails memory localNetworkDetails, Register.NetworkDetails memory remoteNetworkDetails, RebaseToken localToken, RebaseToken remoteToken) public {
        vm.selectFork(localFork);
        vm.startPrank(user);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);

        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: address(localToken),
            amount: amountToBridge
        });
        tokenAmounts[0] = tokenAmount;
        IERC20(address(localToken)).approve(localNetworkDetails.routerAddress, amountToBridge);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user),
            data: "", 
            tokenAmounts: tokenAmounts, 
            feeToken: localNetworkDetails.linkAddress,
            extraArgs:  Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: 1000000 }))
        });

        vm.stopPrank();

        uint256 fee = IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message);
        ccipLocalSimulatorFork.requestLinkFromFaucet(user, fee);

        vm.startPrank(user);
        IERC20(localNetworkDetails.linkAddress).approve(localNetworkDetails.routerAddress, fee);
        
        uint256 localBalanceBefore = IERC20(address(localToken)).balanceOf(user);

        IRouterClient(localNetworkDetails.routerAddress).ccipSend(remoteNetworkDetails.chainSelector, message);
        uint256 localBalanceAfter = IERC20(address(localToken)).balanceOf(user);
        assertEq(localBalanceAfter, localBalanceBefore - amountToBridge);
        vm.stopPrank();

        vm.selectFork(remoteFork);
        vm.warp(block.timestamp + 1 hours);
        uint256 remoteBalanceBefore = IERC20(address(remoteToken)).balanceOf(user);
        vm.selectFork(localFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork);
        assertEq(IERC20(address(remoteToken)).balanceOf(user), remoteBalanceBefore + amountToBridge);
    }

    function testBridgeAllTokens() public {
        configureTokenPool(sepoliaFork, address(sepoliaPool), arbSepoliaNetworkDetails.chainSelector, address(arbSepoliaPool), address(arbSepoliaToken));
        configureTokenPool(arbSepoliaFork, address(arbSepoliaPool), sepoliaNetworkDetails.chainSelector, address(sepoliaPool), address(sepoliaToken));

        vm.selectFork(sepoliaFork);
        vm.deal(user, SEND_VALUE);
        vm.startPrank(user);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        uint256 startValue = IERC20(address(sepoliaToken)).balanceOf(user);
        assertEq(startValue, SEND_VALUE);
        vm.stopPrank();
        bridgeTokens(SEND_VALUE, sepoliaFork, arbSepoliaFork, sepoliaNetworkDetails, arbSepoliaNetworkDetails, sepoliaToken, arbSepoliaToken);

        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 1 hours);
        bridgeTokens(arbSepoliaToken.balanceOf(user), arbSepoliaFork, sepoliaFork, arbSepoliaNetworkDetails, sepoliaNetworkDetails, arbSepoliaToken, sepoliaToken);
    }
}