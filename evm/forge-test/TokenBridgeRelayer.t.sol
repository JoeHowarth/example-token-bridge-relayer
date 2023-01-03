// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {IWETH} from "../src/interfaces/IWETH.sol";
import {IWormhole} from "../src/interfaces/IWormhole.sol";
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {ITokenBridgeRelayer} from "../src/interfaces/ITokenBridgeRelayer.sol";

import {WormholeSimulator} from "wormhole-solidity/WormholeSimulator.sol";
import {ForgeHelpers} from "wormhole-solidity/ForgeHelpers.sol";
import {Helpers} from "./Helpers.sol";

import {TokenBridgeRelayerSetup} from "../src/token-bridge-relayer/TokenBridgeRelayerSetup.sol";
import {TokenBridgeRelayerProxy} from "../src/token-bridge-relayer/TokenBridgeRelayerProxy.sol";
import {TokenBridgeRelayerImplementation} from "../src/token-bridge-relayer/TokenBridgeRelayerImplementation.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title A Test Suite for the EVM Token Bridge Relayer Contracts
 */
contract TestTokenBridgeRelayer is Helpers, ForgeHelpers, Test {
    // guardian private key for simulated signing of Wormhole messages
    uint256 guardianSigner;

    // relayer fee precision
    uint32 relayerFeePrecision;

    // ethereum test info
    uint16 ethereumChainId = uint16(vm.envUint("TESTING_ETH_WORMHOLE_CHAINID"));
    address ethereumTokenBridge = vm.envAddress("TESTING_ETH_BRIDGE_ADDRESS");
    address weth = vm.envAddress("TESTING_WRAPPED_ETH_ADDRESS");
    address ethereumRecipient = vm.envAddress("TESTING_ETH_RECIPIENT");
    address ethUsdc = vm.envAddress("TESTING_ETH_USDC_ADDRESS");

    // avax contract and test info
    IWETH wavax = IWETH(vm.envAddress("TESTING_WRAPPED_AVAX_ADDRESS"));
    address avaxRecipient = vm.envAddress("TESTING_AVAX_RECIPIENT");
    address avaxRelayerWallet = vm.envAddress("TESTING_AVAX_RELAYER");

    // contract instances
    ITokenBridge bridge = ITokenBridge(vm.envAddress("TESTING_AVAX_BRIDGE_ADDRESS"));
    IWormhole wormhole;
    WormholeSimulator wormholeSimulator;
    ITokenBridgeRelayer avaxRelayer;

    // used to compute balance changes before/after redeeming token transfers
    struct Balances {
        uint256 recipientBefore;
        uint256 recipientAfter;
        uint256 relayerBefore;
        uint256 relayerAfter;
    }

    struct NormalizedAmounts {
        uint8 tokenDecimals;
        uint256 transferAmount;
        uint256 relayerFee;
        uint256 toNative;
    }

    function setupWormhole() internal {
        // verify that we're using the correct fork (AVAX mainnet in this case)
        require(block.chainid == vm.envUint("TESTING_AVAX_FORK_CHAINID"), "wrong evm");

        // set up this chain's Wormhole
        wormholeSimulator = new WormholeSimulator(
            vm.envAddress("TESTING_AVAX_WORMHOLE_ADDRESS"),
            uint256(vm.envBytes32("GUARDIAN_KEY")));
        wormhole = wormholeSimulator.wormhole();

        // verify Wormhole state from fork
        require(
            wormhole.chainId() == uint16(vm.envUint("TESTING_AVAX_WORMHOLE_CHAINID")),
            "wrong chainId"
        );
        require(
            wormhole.messageFee() == vm.envUint("TESTING_AVAX_WORMHOLE_MESSAGE_FEE"),
            "wrong messageFee"
        );
        require(
            wormhole.getCurrentGuardianSetIndex() == uint32(
                vm.envUint("TESTING_AVAX_WORMHOLE_GUARDIAN_SET_INDEX")
            ),
            "wrong guardian set index"
        );
    }

    function setupTokenBridgeRelayer() internal {
        // deploy Setup
        TokenBridgeRelayerSetup setup = new TokenBridgeRelayerSetup();

        // deploy Implementation
        TokenBridgeRelayerImplementation implementation =
            new TokenBridgeRelayerImplementation();

        // deploy Proxy
        TokenBridgeRelayerProxy proxy = new TokenBridgeRelayerProxy(
            address(setup),
            abi.encodeWithSelector(
                bytes4(
                    keccak256("setup(address,uint16,address,address,uint256)")
                ),
                address(implementation),
                uint16(wormhole.chainId()),
                address(wormhole),
                vm.envAddress("TESTING_AVAX_BRIDGE_ADDRESS"),
                1e8 // initial swap rate precision
            )
        );
        avaxRelayer = ITokenBridgeRelayer(address(proxy));

        // verify initial state
        assertEq(avaxRelayer.isInitialized(address(implementation)), true);
        assertEq(avaxRelayer.chainId(), wormhole.chainId());
        assertEq(address(avaxRelayer.wormhole()), address(wormhole));
        assertEq(
            address(avaxRelayer.tokenBridge()),
            vm.envAddress("TESTING_AVAX_BRIDGE_ADDRESS")
        );
        assertEq(avaxRelayer.nativeSwapRatePrecision(), 1e8);
    }

    /**
     * @notice Sets up the wormholeSimulator contracts and deploys TokenBridgeRelayer
     * contracts before each test is executed.
     */
    function setUp() public {
        setupWormhole();
        setupTokenBridgeRelayer();
    }

    function getTransferWithPayloadMessage(
        ITokenBridge.TransferWithPayload memory transfer,
        uint16 emitterChainId,
        bytes32 emitterAddress
    ) internal returns (bytes memory signedTransfer) {
        // construct `TransferWithPayload` Wormhole message
        IWormhole.VM memory vm;

        // set the vm values inline
        vm.version = uint8(1);
        vm.timestamp = uint32(block.timestamp);
        vm.emitterChainId = emitterChainId;
        vm.emitterAddress = emitterAddress;
        vm.sequence = wormhole.nextSequence(
            address(uint160(uint256(emitterAddress)))
        );
        vm.consistencyLevel = bridge.finality();
        vm.payload = bridge.encodeTransferWithPayload(transfer);

        // encode the bservation
        signedTransfer = wormholeSimulator.encodeAndSignMessage(vm);
    }

    /**
     * @notice This test confirms that the `TransferTokensWithRelay` method
     * correctly sends an ERC20 token with the `TransferWithRelayer` payload.
     */
    function testTransferTokensWithRelay(
        uint256 amount,
        uint256 toNativeTokenAmount
    ) public {
        // target contract info
        uint256 targetRelayerFee = 1e11;
        bytes32 targetRecipient = addressToBytes32(ethereumRecipient);
        bytes32 targetContract = addressToBytes32(address(this));

        // contract setup
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );
        avaxRelayer.registerToken(avaxRelayer.chainId(), address(wavax));
        avaxRelayer.updateRelayerFee(ethereumChainId, address(wavax), targetRelayerFee);

        // make some assumptions about the fuzz test values
        {
            uint256 normalizedAmount = normalizeAmount(amount, 18);
            uint256 normalizedToNative = normalizeAmount(toNativeTokenAmount, 18);
            uint256 normalizedFee = normalizeAmount(targetRelayerFee, 18);

            vm.assume(normalizedAmount > 0 && amount < type(uint96).max);
            vm.assume(
                normalizedToNative > 0 &&
                toNativeTokenAmount < type(uint96).max &&
                normalizedAmount > normalizedToNative + normalizedFee
            );
        }

        // wrap some avax
        wrap(address(wavax), amount);

        // start listening to events
        vm.recordLogs();

        // approve the relayer contract to spend wavax
        SafeERC20.safeApprove(
            IERC20(address(wavax)),
            address(avaxRelayer),
            amount
        );

        // call the source relayer contract to transfer tokens to ethereum
        uint64 sequence = avaxRelayer.transferTokensWithRelay(
            address(wavax),
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            targetRecipient,
            0 // opt out of batching
        );

        // record the emitted Wormhole message
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "no events recorded");

        // find published wormhole messages from log
        Vm.Log[] memory publishedMessages =
            wormholeSimulator.fetchWormholeMessageFromLog(logs, 1);

        // simulate signing the Wormhole message
        // NOTE: in the wormhole-sdk, signed Wormhole messages are referred to as signed VAAs
        bytes memory encodedMessage = wormholeSimulator.fetchSignedMessageFromLogs(
            publishedMessages[0],
            avaxRelayer.chainId(),
            address(avaxRelayer)
        );

        // parse and verify the message
        (IWormhole.VM memory wormholeMessage, bool valid, ) =
            wormhole.parseAndVerifyVM(encodedMessage);
        require(valid, "failed to verify VAA");

        // call the token bridge to parse the TransferWithPayload message
        ITokenBridge.TransferWithPayload memory transfer =
            bridge.parseTransferWithPayload(wormholeMessage.payload);

        /**
         * The token bridge normalizes the transfer amount to support
         * blockchains that don't support type uint256. We need to normalize the
         * amount we passed to the contract to compare the value against what
         * is encoded in the payload.
         */
        assertEq(
            transfer.amount,
            normalizeAmount(amount, getDecimals(address(wavax)))
        );

        // verify the remaining TransferWithPayload values
        assertEq(transfer.tokenAddress, addressToBytes32(address(wavax)));
        assertEq(transfer.tokenChain, avaxRelayer.chainId());
        assertEq(transfer.to, targetContract);
        assertEq(transfer.toChain, ethereumChainId);
        assertEq(transfer.fromAddress, addressToBytes32(address(avaxRelayer)));
        assertEq(transfer.amount > 0, true);

        // verify VAA values
        assertEq(wormholeMessage.sequence, sequence);
        assertEq(wormholeMessage.nonce, 0); // batchID

        // parse additional payload and verify the values
        ITokenBridgeRelayer.TransferWithRelay memory message =
            avaxRelayer.decodeTransferWithRelay(transfer.payload);

        assertEq(message.payloadId, 1);
        assertEq(
            message.targetRelayerFee,
            normalizeAmount(targetRelayerFee, getDecimals(address(wavax)))
        );
        assertEq(
            message.toNativeTokenAmount,
            normalizeAmount(toNativeTokenAmount, getDecimals(address(wavax)))
        );
        assertEq(message.targetRecipient, targetRecipient);
    }

    /**
     * @notice This test confirms that the `transferTokensWithRelay` method reverts
     * when the token is not registered.
     * @dev this test does not register any tokens on purpose
     */
    function testTransferTokensWithRelayInvalidToken() public {
        address token = address(wavax);
        uint256 amount = 1e18;
        uint256 toNativeTokenAmount = 1e6;
        bytes32 targetContract = addressToBytes32(address(this));

        // wrap some wavax
        wrap(token, amount);

        // register the target contract
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );

        // approve the circle relayer to spend tokesn
        SafeERC20.safeApprove(
            IERC20(token),
            address(avaxRelayer),
            amount
        );

        // the transferTokensWithRelay call should revert
        vm.expectRevert("token not accepted");
        avaxRelayer.transferTokensWithRelay(
            token,
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            targetContract,
            0 // batchId
        );
    }

    /**
     * @notice This test confirms that the `transferTokensWithRelay` method reverts
     * when the target recipient is the zero address.
     */
    function testTransferTokensWithRelayInvalidRecipient() public {
        address token = address(wavax);
        uint256 amount = 1e18;
        uint256 toNativeTokenAmount = 1e6;
        bytes32 targetContract = addressToBytes32(address(this));

        // wrap some wavax
        wrap(token, amount);

        // register the target contract
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), token);

        // approve the circle relayer to spend tokesn
        SafeERC20.safeApprove(
            IERC20(token),
            address(avaxRelayer),
            amount
        );

        // the transferTokensWithRelay call should revert
        vm.expectRevert("targetRecipient cannot be bytes32(0)");
        avaxRelayer.transferTokensWithRelay(
            token,
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            bytes32(0),
            0 // batchId
        );
    }

    /**
     * @notice This test confirms that the `transferTokensWithRelay` method reverts
     * when the target contract is not registered.
     * @dev this test does not register a target contract on purpose
     */
    function testTransferTokensWithRelayInvalidTargetContract() public {
        address token = address(wavax);
        uint256 amount = 1e18;
        uint256 toNativeTokenAmount = 1e11;

        // wrap some wavax
        wrap(token, amount);

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), token);

        // approve the circle relayer to spend tokesn
        SafeERC20.safeApprove(
            IERC20(token),
            address(avaxRelayer),
            amount
        );

        // the transferTokensWithRelay call should revert
        vm.expectRevert("target not registered");
        avaxRelayer.transferTokensWithRelay(
            token,
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            addressToBytes32(address(this)),
            0 // batchId
        );
    }

    /**
     * @notice This test confirms that the `transferTokensWithRelay` method reverts
     * when the normalized transfer amount is not greater than zero.
     */
    function testTransferTokensWithRelayInsufficientNormalizedAmount(
        uint256 amount
    ) public {
        vm.assume(
            amount > 0 &&
            normalizeAmount(amount, 18) == 0
        );

        address token = address(wavax);
        uint256 toNativeTokenAmount = 0;
        bytes32 targetContract = addressToBytes32(address(this));

        // wrap some wavax
        wrap(token, amount);

        // register the target contract
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), token);

        // approve the circle relayer to spend tokesn
        SafeERC20.safeApprove(
            IERC20(token),
            address(avaxRelayer),
            amount
        );

        // the transferTokensWithRelay call should revert
        vm.expectRevert("normalized amount must be > 0");
        avaxRelayer.transferTokensWithRelay(
            token,
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            addressToBytes32(address(this)),
            0 // batchId
        );
    }

     /**
     * @notice This test confirms that the `transferTokensWithRelay` method reverts
     * when the normalized toNativeTokenAmount is not greater than zero.
     */
    function testTransferTokensWithRelayInsufficientNormalizedAmount() public {
        address token = address(wavax);
        uint256 amount = 6.9e18;
        uint256 toNativeTokenAmount = 1e6; // normalized amount should be zero
        bytes32 targetContract = addressToBytes32(address(this));

        require(normalizeAmount(toNativeTokenAmount, 18) == 0, "bad test setup");

        // wrap some wavax
        wrap(token, amount);

        // register the target contract
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), token);

        // approve the circle relayer to spend tokesn
        SafeERC20.safeApprove(
            IERC20(token),
            address(avaxRelayer),
            amount
        );

        // the transferTokensWithRelay call should revert
        vm.expectRevert("normalized toNativeTokenAmount must be > 0");
        avaxRelayer.transferTokensWithRelay(
            token,
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            addressToBytes32(address(this)),
            0 // batchId
        );
    }

    /**
     * @notice This test confirms that the `transferTokensWithRelay` method reverts
     * when the transfer amount isn't large enough to cover the relayer fee and
     * the to native token swap amount.
     */
    function testTransferTokensWithRelayInsufficientAmount() public {
        address token = address(wavax);
        bytes32 targetContract = addressToBytes32(address(this));

        // define amounts
        uint256 relayerFee = 1e11;
        uint256 amount = 1e18;
        uint256 toNativeTokenAmount = 1e18 - 1;
        require(amount < relayerFee + toNativeTokenAmount, "bad test setup");

        // wrap some wavax
        wrap(token, amount);

        // register the target contract
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), token);

        // update the relayer fee
        avaxRelayer.updateRelayerFee(
            ethereumChainId,
            token,
            relayerFee
        );

        // approve the circle relayer to spend tokesn
        SafeERC20.safeApprove(
            IERC20(token),
            address(avaxRelayer),
            amount
        );

        // the transferTokensWithRelay call should revert
        vm.expectRevert("insufficient amount");
        avaxRelayer.transferTokensWithRelay(
            token,
            amount,
            toNativeTokenAmount,
            ethereumChainId,
            addressToBytes32(address(this)),
            0 // batchId
        );
    }

    /**
     * @notice This test confirms that the `wrapAndTransferEthWithRelay` method
     * correctly sends native assets with the `TransferWithRelayer` payload.
     */
    function testWrapAndTransferEthWithRelay(
        uint256 amount,
        uint256 toNativeTokenAmount
    ) public {
        // target contract info
        uint256 targetRelayerFee = 1e11;
        bytes32 targetRecipient = addressToBytes32(ethereumRecipient);
        bytes32 targetContract = addressToBytes32(address(this));

        // contract setup
        avaxRelayer.registerContract(
            ethereumChainId,
            targetContract
        );
        avaxRelayer.registerToken(avaxRelayer.chainId(), address(wavax));
        avaxRelayer.updateRelayerFee(ethereumChainId, address(wavax), targetRelayerFee);

        // make some assumptions about the fuzz test values
        {
            uint256 normalizedAmount = normalizeAmount(amount, 18);
            uint256 normalizedToNative = normalizeAmount(toNativeTokenAmount, 18);
            uint256 normalizedFee = normalizeAmount(targetRelayerFee, 18);

            vm.assume(normalizedAmount > 0 && amount < type(uint96).max);
            vm.assume(
                normalizedToNative > 0 &&
                toNativeTokenAmount < type(uint96).max &&
                normalizedAmount > normalizedToNative + normalizedFee
            );
        }

        // start listening to events
        vm.recordLogs();

        // hoax the recipient and balance check before
        hoax(avaxRecipient, amount);
        uint256 balanceBefore = avaxRecipient.balance;

        // call the source relayer contract to transfer ETH
        uint64 sequence = avaxRelayer.wrapAndTransferEthWithRelay{value: amount}(
            toNativeTokenAmount,
            ethereumChainId,
            targetRecipient,
            0 // opt out of batching
        );

        /**
         * Balance check the recipient's wallet. Denormalizing the amount
         * accounts for the "dust" refund the contract sends after normalizing
         * the transfer amount.
         */
        assertEq(
            balanceBefore - avaxRecipient.balance,
            denormalizeAmount(
                normalizeAmount(amount, 18),
                18
            )
        );

        // record the emitted Wormhole message
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "no events recorded");

        // find published wormhole messages from log
        Vm.Log[] memory publishedMessages =
            wormholeSimulator.fetchWormholeMessageFromLog(logs, 1);

        // simulate signing the Wormhole message
        // NOTE: in the wormhole-sdk, signed Wormhole messages are referred to as signed VAAs
        bytes memory encodedMessage = wormholeSimulator.fetchSignedMessageFromLogs(
            publishedMessages[0],
            avaxRelayer.chainId(),
            address(avaxRelayer)
        );

        // parse and verify the message
        (IWormhole.VM memory wormholeMessage, bool valid, ) =
            wormhole.parseAndVerifyVM(encodedMessage);
        require(valid, "failed to verify VAA");

        // call the token bridge to parse the TransferWithPayload message
        ITokenBridge.TransferWithPayload memory transfer =
            bridge.parseTransferWithPayload(wormholeMessage.payload);

        /**
         * The token bridge normalizes the transfer amount to support
         * blockchains that don't support type uint256. We need to normalize the
         * amount we passed to the contract to compare the value against what
         * is encoded in the payload.
         */
        assertEq(
            transfer.amount,
            normalizeAmount(amount, 18)
        );

        // verify the remaining TransferWithPayload values
        assertEq(transfer.tokenAddress, addressToBytes32(address(wavax)));
        assertEq(transfer.tokenChain, avaxRelayer.chainId());
        assertEq(transfer.to, targetContract);
        assertEq(transfer.toChain, ethereumChainId);
        assertEq(transfer.fromAddress, addressToBytes32(address(avaxRelayer)));
        assertEq(transfer.amount > 0, true);

        // verify VAA values
        assertEq(wormholeMessage.sequence, sequence);
        assertEq(wormholeMessage.nonce, 0); // batchID

        // parse additional payload and verify the values
        ITokenBridgeRelayer.TransferWithRelay memory message =
            avaxRelayer.decodeTransferWithRelay(transfer.payload);

        assertEq(message.payloadId, 1);
        assertEq(
            message.targetRelayerFee,
            normalizeAmount(targetRelayerFee, 18)
        );
        assertEq(
            message.toNativeTokenAmount,
            normalizeAmount(toNativeTokenAmount, 18)
        );
        assertEq(message.targetRecipient, targetRecipient);
    }

    /**
     * @notice This test confirms that relayer contract correctly redeems wrapped
     * native tokens to the encoded recipient and handles relayer payments correctly.
     * @dev The minimum amount value has to be greater than 1e10. The token bridge
     * will truncate the value to zero if it's less than 1e10.
     */
    function testCompleteTransferWithRelayWrappedNative(
        uint256 amount,
        uint256 toNativeTokenAmount
    ) public {
        // encoded relayer fee (must be > 1e10 or it will be truncated to zero)
        uint256 encodedRelayerFee = 1.1e11;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );

        // store normalized transfer amounts to reduce local variable count
        NormalizedAmounts memory normAmounts;
        normAmounts.tokenDecimals = getDecimals(wrappedAsset);
        normAmounts.transferAmount = normalizeAmount(
            amount,
            normAmounts.tokenDecimals
        );
        normAmounts.relayerFee = normalizeAmount(
            encodedRelayerFee,
            normAmounts.tokenDecimals
        );
        normAmounts.toNative = normalizeAmount(
            toNativeTokenAmount,
            normAmounts.tokenDecimals
        );

        // test setup
        {
            // make some assumptions about the fuzz test values
            vm.assume(
                normAmounts.transferAmount > 0 &&
                amount < type(uint96).max
            );
            vm.assume(
                normAmounts.toNative > 0 &&
                toNativeTokenAmount < type(uint96).max &&
                normAmounts.transferAmount > normAmounts.toNative + normAmounts.relayerFee
            );

            // target contract setup
            avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

            // update the relayer fee
            avaxRelayer.updateRelayerFee(
                avaxRelayer.chainId(),
                wrappedAsset,
                encodedRelayerFee
            );

            // register this contract as the foreign emitter
            avaxRelayer.registerContract(
                ethereumChainId,
                addressToBytes32(address(this))
            );

            // set the native swap rate
            avaxRelayer.updateNativeSwapRate(
                avaxRelayer.chainId(),
                wrappedAsset,
                6.9e3 * avaxRelayer.nativeSwapRatePrecision() // swap rate
            );

            // set the max to native amount
            avaxRelayer.updateMaxNativeSwapAmount(
                avaxRelayer.chainId(),
                wrappedAsset,
                6.9e18 // max native swap amount
            );
        }

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normAmounts.relayerFee,
                toNativeTokenAmount: normAmounts.toNative,
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normAmounts.transferAmount,
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // fetch token balances
        Balances memory tokenBalances;
        tokenBalances.recipientBefore = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerBefore = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient
        Balances memory ethBalances;
        ethBalances.recipientBefore = avaxRecipient.balance;

        // Get a quote from the contract for the native gas swap. Denormalize
        // the amount to get a more accurate quote, and reduce gas costs.
        uint256 nativeGasQuote = avaxRelayer.calculateNativeSwapAmountOut(
            wrappedAsset,
            denormalizeAmount(normAmounts.toNative, normAmounts.tokenDecimals)
        );

        // hoax relayer and balance check
        hoax(avaxRelayerWallet, nativeGasQuote);
        ethBalances.relayerBefore = avaxRelayerWallet.balance;

        // call redeemTokens from relayer wallet
        avaxRelayer.completeTransferWithRelay{value: nativeGasQuote}(signedMessage);

        // check token balance of the recipient and relayer
        tokenBalances.recipientAfter = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerAfter = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient and relayer
        ethBalances.recipientAfter = avaxRecipient.balance;
        ethBalances.relayerAfter = avaxRelayerWallet.balance;

        // validate results
        {
            /**
            * Overwrite the toNativeTokenAmount if the value is larger than
            * the max swap amount. The contract executes the same instruction.
            */
            uint256 maxToNative = avaxRelayer.calculateMaxSwapAmountIn(wrappedAsset);
            uint256 denormToNativeAmount = denormalizeAmount(
                normAmounts.toNative,
                normAmounts.tokenDecimals
            );
            if (denormToNativeAmount > maxToNative) {
                denormToNativeAmount = maxToNative;
            }

            /**
            * Set the toNativeTokenAmount to zero if the nativeGasQuote is zero.
            * The nativeGasQuote can be zero if the toNativeTokenAmount is too little
            * to convert to native assets (solidity rounds towards zero).
            */
            if (nativeGasQuote == 0) {
                denormToNativeAmount = 0;
            }

            // calculate the denormalized amount and relayer fee
            uint256 denormAmount = denormalizeAmount(
                normAmounts.transferAmount,
                normAmounts.tokenDecimals
            );
            uint256 denormRelayerFee = denormalizeAmount(
                normAmounts.relayerFee,
                normAmounts.tokenDecimals
            );

            // validate token balances
            assertEq(
                tokenBalances.recipientAfter - tokenBalances.recipientBefore,
                denormAmount - denormRelayerFee - denormToNativeAmount
            );
            assertEq(
                tokenBalances.relayerAfter - tokenBalances.relayerBefore,
                denormRelayerFee + denormToNativeAmount
            );

            // validate eth balances
            uint256 maxNativeSwapAmount = avaxRelayer.maxNativeSwapAmount(wrappedAsset);
            assertEq(
                ethBalances.recipientAfter - ethBalances.recipientBefore,
                nativeGasQuote > maxNativeSwapAmount ? maxNativeSwapAmount : nativeGasQuote
            );
            assertEq(
                ethBalances.relayerBefore - ethBalances.relayerAfter,
                nativeGasQuote > maxNativeSwapAmount ? maxNativeSwapAmount : nativeGasQuote
            );
        }
    }

    /**
     * @notice This test confirms that relayer contract correctly redeems wrapped
     * native tokens to the encoded recipient and handles relayer payments correctly.
     * This tests explicitly encodes a relayer fee that is less than the fee in the
     * relayer contract's state. The contract should use the minimum of the two.
     * @dev The minimum amount value has to be greater than 1e10. The token bridge
     * will truncate the value to zero if it's less than 1e10.
     */
    function testCompleteTransferWithRelayWrappedNativeInconsistentFees(
        uint256 encodedRelayerFee
    ) public {
        // encoded relayer fee (must be > 1e10 or it will be truncated to zero)
        uint256 stateRelayerFee = 4.2e18;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );

        // store normalized transfer amounts to reduce local variable count
        NormalizedAmounts memory normAmounts;
        normAmounts.tokenDecimals = getDecimals(wrappedAsset);
        // NOTE: set the encoded relayer fee to zero
        normAmounts.relayerFee = normalizeAmount(
            encodedRelayerFee,
            normAmounts.tokenDecimals
        );

        // NOTE: hardcode the amount and toNativeTokenAmount
        normAmounts.transferAmount = normalizeAmount(
            6.9e18,
            normAmounts.tokenDecimals
        );
        normAmounts.toNative = 0;

        // test setup
        {
            // make some assumptions about the fuzz test values
            vm.assume(
                encodedRelayerFee < stateRelayerFee &&
                normAmounts.relayerFee > 0 &&
                normAmounts.relayerFee < normAmounts.transferAmount
            );


            // target contract setup
            avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

            // update the relayer fee with the state relayer fee
            avaxRelayer.updateRelayerFee(
                avaxRelayer.chainId(),
                wrappedAsset,
                stateRelayerFee
            );

            // register this contract as the foreign emitter
            avaxRelayer.registerContract(
                ethereumChainId,
                addressToBytes32(address(this))
            );

            // set the native swap rate
            avaxRelayer.updateNativeSwapRate(
                avaxRelayer.chainId(),
                wrappedAsset,
                6.9e3 * avaxRelayer.nativeSwapRatePrecision() // swap rate
            );

            // set the max to native amount
            avaxRelayer.updateMaxNativeSwapAmount(
                avaxRelayer.chainId(),
                wrappedAsset,
                6.9e18 // max native swap amount
            );
        }

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normAmounts.relayerFee,
                toNativeTokenAmount: normAmounts.toNative,
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normAmounts.transferAmount,
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // fetch token balances
        Balances memory tokenBalances;
        tokenBalances.recipientBefore = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerBefore = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // prank relayer wallet and balance check
        vm.prank(avaxRelayerWallet);

        // call redeemTokens from relayer wallet
        avaxRelayer.completeTransferWithRelay(signedMessage);

        // check token balance of the recipient and relayer
        tokenBalances.recipientAfter = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerAfter = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // // validate results
        {
            // calculate the denormalized amount and relayer fee
            uint256 denormAmount = denormalizeAmount(
                normAmounts.transferAmount,
                normAmounts.tokenDecimals
            );
            uint256 denormRelayerFee = denormalizeAmount(
                normAmounts.relayerFee,
                normAmounts.tokenDecimals
            );
            require(
                denormRelayerFee < avaxRelayer.relayerFee(
                    avaxRelayer.chainId(), wrappedAsset
                ),
                "oops"
            );

            // validate token balances
            assertEq(
                tokenBalances.recipientAfter - tokenBalances.recipientBefore,
                denormAmount - denormRelayerFee
            );

            /**
             * Validate the balance change for the relayer, the relayer should be
             * paid the encodedRelayer fee instead of the stateRelayerFee, since the
             * contract will pay the minimum of the two.
             */
            assertEq(
                tokenBalances.relayerAfter - tokenBalances.relayerBefore,
                denormRelayerFee
            );
        }
    }

    /**
     * @notice This test confirms that relayer contract correctly redeems wrapped
     * native tokens to the encoded recipient. This test explicitly sets the
     * relayerFee and toNativeTokenAmount to zero.
     * @dev The minimum amount value has to be greater than 1e10. The token bridge
     * will truncate the value to zero if it's less than 1e10.
     */
    function testCompleteTransferWithRelayWrappedNativeNoFeesOrSwap(
        uint256 amount
    ) public {
        // set the relayerFee and toNativeTokenAmount to zero
        uint256 encodedRelayerFee = 0;
        uint256 toNativeTokenAmount = 0;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );

        // store normalized transfer amounts to reduce local variable count
        NormalizedAmounts memory normAmounts;
        normAmounts.tokenDecimals = getDecimals(wrappedAsset);
        normAmounts.transferAmount = normalizeAmount(
            amount,
            normAmounts.tokenDecimals
        );

        // test setup
        {
            // make some assumptions about the fuzz test values
            vm.assume(
                normAmounts.transferAmount > 0 &&
                amount < type(uint96).max
            );

            // target contract setup
            avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

            // update the relayer fee
            avaxRelayer.updateRelayerFee(
                avaxRelayer.chainId(),
                wrappedAsset,
                encodedRelayerFee
            );

            // register this contract as the foreign emitter
            avaxRelayer.registerContract(
                ethereumChainId,
                addressToBytes32(address(this))
            );

            // set the native swap rate
            avaxRelayer.updateNativeSwapRate(
                avaxRelayer.chainId(),
                wrappedAsset,
                6.9e3 * avaxRelayer.nativeSwapRatePrecision() // swap rate
            );
        }

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: encodedRelayerFee,
                toNativeTokenAmount: toNativeTokenAmount,
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normAmounts.transferAmount,
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // fetch token balances
        Balances memory tokenBalances;
        tokenBalances.recipientBefore = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerBefore = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient
        Balances memory ethBalances;
        ethBalances.recipientBefore = avaxRecipient.balance;

        // get a quote from the contract for the native gas swap
        uint256 nativeGasQuote = avaxRelayer.calculateNativeSwapAmountOut(
            wrappedAsset,
            toNativeTokenAmount // zero, so don't need to denormalize
        );
        require(nativeGasQuote == 0, "oops");

        // hoax relayer and balance check
        vm.prank(avaxRelayerWallet);
        ethBalances.relayerBefore = avaxRelayerWallet.balance;

        // call redeemTokens from relayer wallet
        avaxRelayer.completeTransferWithRelay(signedMessage);

        // check token balance of the recipient and relayer
        tokenBalances.recipientAfter = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerAfter = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient and relayer
        ethBalances.recipientAfter = avaxRecipient.balance;
        ethBalances.relayerAfter = avaxRelayerWallet.balance;

        // validate results
        {
            // calculate the denormalized amount and relayer fee
            uint256 denormAmount = denormalizeAmount(
                normAmounts.transferAmount,
                normAmounts.tokenDecimals
            );

            // validate token balances
            assertEq(
                tokenBalances.recipientAfter - tokenBalances.recipientBefore,
                denormAmount
            );
            assertEq(tokenBalances.relayerAfter, tokenBalances.relayerBefore);

            // validate eth balances
            assertEq(ethBalances.recipientAfter, ethBalances.recipientBefore);
            assertEq(ethBalances.relayerBefore, ethBalances.relayerAfter);
        }
    }

    /**
     * @notice This test confirms that relayer contract correctly redeems wrapped
     * native tokens to the encoded recipient and handles relayer payments correctly.
     * It also confirms that the contract refunds the relayer any excess native gas
     * that it passed to the contract.
     * @dev The minimum amount value has to be greater than 1e10. The token bridge
     * will truncate the value to zero if it's less than 1e10.
     */
    function testCompleteTransferWithRelayWrappedNativeRelayerRefund(
        uint256 additionalGas
    ) public {
        // set transfer param values (must be > 1e10)
        uint256 encodedRelayerFee = 1.1e11;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );

        // store normalized transfer amounts to reduce local variable count
        NormalizedAmounts memory normAmounts;
        normAmounts.tokenDecimals = getDecimals(wrappedAsset);
        normAmounts.transferAmount = normalizeAmount(
            4.2e18, // transfer amount
            normAmounts.tokenDecimals
        );
        normAmounts.relayerFee = normalizeAmount(
            encodedRelayerFee,
            normAmounts.tokenDecimals
        );
        normAmounts.toNative = normalizeAmount(
            6.9e16, // toNativeTokenAmount
            normAmounts.tokenDecimals
        );

        // test setup
        {
            vm.assume(additionalGas > 0 && additionalGas < type(uint64).max);

            // target contract setup
            avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

            // update the relayer fee
            avaxRelayer.updateRelayerFee(
                avaxRelayer.chainId(),
                wrappedAsset,
                encodedRelayerFee
            );

            // register this contract as the foreign emitter
            avaxRelayer.registerContract(
                ethereumChainId,
                addressToBytes32(address(this))
            );

            // set the native swap rate
            avaxRelayer.updateNativeSwapRate(
                avaxRelayer.chainId(),
                wrappedAsset,
                6.9e3 * avaxRelayer.nativeSwapRatePrecision() // swap rate
            );

            // NOTE: Don't set the max native swap amount so that it defaults to zero
        }

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normAmounts.relayerFee,
                toNativeTokenAmount: normAmounts.toNative,
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normAmounts.transferAmount,
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // fetch token balances
        Balances memory tokenBalances;
        tokenBalances.recipientBefore = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerBefore = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient
        Balances memory ethBalances;
        ethBalances.recipientBefore = avaxRecipient.balance;

        // Get a quote from the contract for the native gas swap. Denormalize
        // the amount to get a more accurate quote, and reduce gas costs.
        uint256 nativeGasQuote = avaxRelayer.calculateNativeSwapAmountOut(
            wrappedAsset,
            denormalizeAmount(normAmounts.toNative, normAmounts.tokenDecimals)
        );

        // hoax relayer and balance check
        hoax(avaxRelayerWallet, nativeGasQuote + additionalGas);
        ethBalances.relayerBefore = avaxRelayerWallet.balance;

        // NOTE: Pass additional gas to the relayer contract to confirm that
        // it correctly refunds the relayer.
        avaxRelayer.completeTransferWithRelay{
            value: nativeGasQuote + additionalGas
        }(signedMessage);

        // check token balance of the recipient and relayer
        tokenBalances.recipientAfter = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerAfter = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient and relayer
        ethBalances.recipientAfter = avaxRecipient.balance;
        ethBalances.relayerAfter = avaxRelayerWallet.balance;

        // validate results
        {
            /**
            * Overwrite the toNativeTokenAmount if the value is larger than
            * the max swap amount. The contract executes the same instruction.
            */
            uint256 maxToNative = avaxRelayer.calculateMaxSwapAmountIn(wrappedAsset);
            uint256 denormToNativeAmount = denormalizeAmount(
                normAmounts.toNative,
                normAmounts.tokenDecimals
            );
            if (denormToNativeAmount > maxToNative) {
                denormToNativeAmount = maxToNative;
            }

            /**
            * Set the toNativeTokenAmount to zero if the nativeGasQuote is zero.
            * The nativeGasQuote can be zero if the toNativeTokenAmount is too little
            * to convert to native assets (solidity rounds towards zero).
            */
            if (nativeGasQuote == 0) {
                denormToNativeAmount = 0;
            }

            // calculate the denormalized amount and relayer fee
            uint256 denormAmount = denormalizeAmount(
                normAmounts.transferAmount,
                normAmounts.tokenDecimals
            );
            uint256 denormRelayerFee = denormalizeAmount(
                normAmounts.relayerFee,
                normAmounts.tokenDecimals
            );

            // validate token balances
            assertEq(
                tokenBalances.recipientAfter - tokenBalances.recipientBefore,
                denormAmount - denormRelayerFee - denormToNativeAmount
            );
            assertEq(
                tokenBalances.relayerAfter - tokenBalances.relayerBefore,
                denormRelayerFee + denormToNativeAmount
            );

            // validate eth balances
            uint256 maxNativeSwapAmount = avaxRelayer.maxNativeSwapAmount(wrappedAsset);
            assertEq(
                ethBalances.recipientAfter - ethBalances.recipientBefore,
                nativeGasQuote > maxNativeSwapAmount ? maxNativeSwapAmount : nativeGasQuote
            );

            // NOTE: Verify that the relayer was refunded. If it wasn't than the
            // require statement would trigger.
            require(
                nativeGasQuote + additionalGas > nativeGasQuote &&
                maxNativeSwapAmount == 0,
                "oops"
            );
            assertEq(
                ethBalances.relayerBefore - ethBalances.relayerAfter,
                nativeGasQuote > maxNativeSwapAmount ? maxNativeSwapAmount : nativeGasQuote
            );
        }
    }

    /**
     * @notice This test confirms that relayer contract correctly redeems wrapped
     * native tokens to the self redeeming recipient. The contract will not pay a
     * relayer fee or allow any token swaps.
     */
    function testCompleteTransferWithRelayWrappedNativeSelfRedeem(
        uint256 amount,
        uint256 toNativeTokenAmount
    ) public {
        // encoded relayer fee (must be > 1e10 or it will be truncated to zero)
        uint256 encodedRelayerFee = 1.1e11;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );

        // store normalized transfer amounts to reduce local variable count
        NormalizedAmounts memory normAmounts;
        normAmounts.tokenDecimals = getDecimals(wrappedAsset);
        normAmounts.transferAmount = normalizeAmount(
            amount,
            normAmounts.tokenDecimals
        );
        normAmounts.relayerFee = normalizeAmount(
            encodedRelayerFee,
            normAmounts.tokenDecimals
        );
        normAmounts.toNative = normalizeAmount(
            toNativeTokenAmount,
            normAmounts.tokenDecimals
        );

        // test setup
        {
            // make some assumptions about the fuzz test values
            vm.assume(
                normAmounts.transferAmount > 0 &&
                amount < type(uint96).max
            );
            vm.assume(
                normAmounts.toNative > 0 &&
                toNativeTokenAmount < type(uint96).max &&
                normAmounts.transferAmount > normAmounts.toNative + normAmounts.relayerFee
            );

            // target contract setup
            avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

            // update the relayer fee
            avaxRelayer.updateRelayerFee(
                avaxRelayer.chainId(),
                wrappedAsset,
                encodedRelayerFee
            );

            // register this contract as the foreign emitter
            avaxRelayer.registerContract(
                ethereumChainId,
                addressToBytes32(address(this))
            );
        }

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normAmounts.relayerFee,
                toNativeTokenAmount: normAmounts.toNative,
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normAmounts.transferAmount,
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // fetch token balances
        Balances memory tokenBalances;
        tokenBalances.recipientBefore = getBalance(
            wrappedAsset,
            avaxRecipient
        );

        // check the native balance of the recipient
        Balances memory ethBalances;
        ethBalances.recipientBefore = avaxRecipient.balance;

        // call complete transfer from the recipients wallet
        vm.prank(avaxRecipient);
        avaxRelayer.completeTransferWithRelay(signedMessage);

        // check token balance of the recipient and relayer
        tokenBalances.recipientAfter = getBalance(
            wrappedAsset,
            avaxRecipient
        );

        // check the native balance of the recipient and relayer
        ethBalances.recipientAfter = avaxRecipient.balance;

        // validate results
        {
            // calculate the denormalized amount and relayer fee
            uint256 denormAmount = denormalizeAmount(
                normAmounts.transferAmount,
                normAmounts.tokenDecimals
            );

            // validate token balances
            assertEq(
                tokenBalances.recipientAfter - tokenBalances.recipientBefore,
                denormAmount
            );

            // validate eth balances
            assertEq(ethBalances.recipientAfter, ethBalances.recipientBefore);
        }
    }

    /**
     * @notice This test confirms that relayer contract correctly redeems wrapped
     * stablecoins to the encoded recipient and handles relayer payments correctly.
     * @dev The contract behavior changes slight when transferring stablecoins
     * since the contracts will not normalize the quantities (decimals < 8).
     */
    function testCompleteTransferWithRelayWrappedStable(
        uint256 amount,
        uint256 toNativeTokenAmount
    ) public {
        // encoded relayer fee
        uint256 encodedRelayerFee = 6.9e6;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(ethUsdc)
        );

        // test setup
        {
            // make some assumptions about the fuzz test values
            vm.assume(
                amount > 0 &&
                amount < type(uint96).max
            );
            vm.assume(
                toNativeTokenAmount > 0 &&
                toNativeTokenAmount < type(uint96).max &&
                amount > toNativeTokenAmount + encodedRelayerFee
            );

            // target contract setup
            avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

            // update the relayer fee
            avaxRelayer.updateRelayerFee(
                avaxRelayer.chainId(),
                wrappedAsset,
                encodedRelayerFee
            );

            // register this contract as the foreign emitter
            avaxRelayer.registerContract(
                ethereumChainId,
                addressToBytes32(address(this))
            );

            // set the native swap rate
            avaxRelayer.updateNativeSwapRate(
                avaxRelayer.chainId(),
                wrappedAsset,
                1 * avaxRelayer.nativeSwapRatePrecision() // swap rate
            );

            // set the max to native amount
            avaxRelayer.updateMaxNativeSwapAmount(
                avaxRelayer.chainId(),
                wrappedAsset,
                1e18 // max native swap amount
            );
        }

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: encodedRelayerFee,
                toNativeTokenAmount: toNativeTokenAmount,
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: amount,
                tokenAddress: addressToBytes32(ethUsdc),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // fetch token balances
        Balances memory tokenBalances;
        tokenBalances.recipientBefore = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerBefore = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient
        Balances memory ethBalances;
        ethBalances.recipientBefore = avaxRecipient.balance;

        // get a quote from the contract for the native gas swap
        uint256 nativeGasQuote = avaxRelayer.calculateNativeSwapAmountOut(
            wrappedAsset,
            toNativeTokenAmount
        );

        // hoax relayer and balance check
        hoax(avaxRelayerWallet, nativeGasQuote);
        ethBalances.relayerBefore = avaxRelayerWallet.balance;

        // call redeemTokens from relayer wallet
        avaxRelayer.completeTransferWithRelay{value: nativeGasQuote}(signedMessage);

        // check token balance of the recipient and relayer
        tokenBalances.recipientAfter = getBalance(
            wrappedAsset,
            avaxRecipient
        );
        tokenBalances.relayerAfter = getBalance(
            wrappedAsset,
            avaxRelayerWallet
        );

        // check the native balance of the recipient and relayer
        ethBalances.recipientAfter = avaxRecipient.balance;
        ethBalances.relayerAfter = avaxRelayerWallet.balance;

        // validate results
        {
            /**
            * Overwrite the toNativeTokenAmount if the value is larger than
            * the max swap amount. The contract executes the same instruction.
            */
            uint256 maxToNative = avaxRelayer.calculateMaxSwapAmountIn(wrappedAsset);
            if (toNativeTokenAmount > maxToNative) {
                toNativeTokenAmount = maxToNative;
            }

            /**
            * Set the toNativeTokenAmount to zero if the nativeGasQuote is zero.
            * The nativeGasQuote can be zero if the toNativeTokenAmount is too little
            * to convert to native assets (solidity rounds towards zero).
            */
            if (nativeGasQuote == 0) {
                toNativeTokenAmount = 0;
            }

            // validate token balances
            assertEq(
                tokenBalances.recipientAfter - tokenBalances.recipientBefore,
                amount - toNativeTokenAmount - encodedRelayerFee
            );
            assertEq(
                tokenBalances.relayerAfter - tokenBalances.relayerBefore,
                encodedRelayerFee + toNativeTokenAmount
            );

            // validate eth balances
            uint256 maxNativeSwapAmount = avaxRelayer.maxNativeSwapAmount(wrappedAsset);
            assertEq(
                ethBalances.recipientAfter - ethBalances.recipientBefore,
                nativeGasQuote > maxNativeSwapAmount ? maxNativeSwapAmount : nativeGasQuote
            );
            assertEq(
                ethBalances.relayerBefore - ethBalances.relayerAfter,
                nativeGasQuote > maxNativeSwapAmount ? maxNativeSwapAmount : nativeGasQuote
            );
        }
    }

    /**
     * @notice This test confirms that relayer contract reverts when receiving
     * a transfer for an unregistered token.
     */
    function testCompleteTransferWithRelayUnregisteredToken() public {
        uint256 relayerFee = 1.1e11;
        uint256 amount = 1e19;
        uint256 toNativeTokenAmount = 1e10;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );
        uint8 tokenDecimals = getDecimals(wrappedAsset);

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normalizeAmount(relayerFee, tokenDecimals),
                toNativeTokenAmount: normalizeAmount(
                    toNativeTokenAmount,
                    tokenDecimals
                ),
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normalizeAmount(amount, tokenDecimals),
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // the completeTransferWithRelay call should revert
        vm.expectRevert("token not registered");
        avaxRelayer.completeTransferWithRelay(signedMessage);
    }

    /**
     * @notice This test confirms that relayer contract reverts when receiving
     * a transfer from an unregistered contract.
     */
    function testCompleteTransferWithRelayUnregisteredContract() public {
        uint256 relayerFee = 1.1e11;
        uint256 amount = 1e19;
        uint256 toNativeTokenAmount = 1e10;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );
        uint8 tokenDecimals = getDecimals(wrappedAsset);

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normalizeAmount(relayerFee, tokenDecimals),
                toNativeTokenAmount: normalizeAmount(
                    toNativeTokenAmount,
                    tokenDecimals
                ),
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normalizeAmount(amount, tokenDecimals),
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // target contract setup
        avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

        // the completeTransferWithRelay call should revert
        vm.expectRevert("contract not registered");
        avaxRelayer.completeTransferWithRelay(signedMessage);
    }

    /**
     * @notice This test confirms that relayer contract reverts when the recipient
     * tries to redeem their transfer and swap native assets.
     */
    function testCompleteTransferWithRelayInvalidSelfRedeem() public {
        uint256 relayerFee = 1.1e11;
        uint256 amount = 1e19;
        uint256 toNativeTokenAmount = 1e10;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );
        uint8 tokenDecimals = getDecimals(wrappedAsset);

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normalizeAmount(relayerFee, tokenDecimals),
                toNativeTokenAmount: normalizeAmount(
                    toNativeTokenAmount,
                    tokenDecimals
                ),
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normalizeAmount(amount, tokenDecimals),
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

        // register this contract as the foreign emitter
        avaxRelayer.registerContract(
            ethereumChainId,
            addressToBytes32(address(this))
        );

        // set the native swap rate (so the native gas query works)
        avaxRelayer.updateNativeSwapRate(
            avaxRelayer.chainId(),
            wrappedAsset,
            1 * avaxRelayer.nativeSwapRatePrecision() // swap rate
        );

        // get a quote from the contract for the native gas swap
        uint256 nativeGasQuote = avaxRelayer.calculateNativeSwapAmountOut(
            wrappedAsset,
            denormalizeAmount(
                normalizeAmount(toNativeTokenAmount, tokenDecimals),
                tokenDecimals
            )
        );

        // NOTE: hoax the recipient wallet to test self redemption
        hoax(avaxRecipient, nativeGasQuote);

        // expect the completeTransferWithRelay call to fail
        vm.expectRevert("recipient cannot swap native assets");
        avaxRelayer.completeTransferWithRelay{value: nativeGasQuote}(signedMessage);
    }

    /**
     * @notice This test confirms that relayer contract reverts when the
     * off-chain relayer fails to provide enough native assets to facilitate
     * the swap requested by the recipient.
     * @dev this test explicitly sets value to 0 when completing the transfer
     */
    function testCompleteTransferWithRelayInsufficientSwapAmount() public {
        uint256 relayerFee = 1.1e11;
        uint256 amount = 1e19;
        uint256 toNativeTokenAmount = 1e17;

        // Fetch the wrapped weth contract on avalanche, since the token
        // address encoded in the signedMessage is weth from Ethereum.
        address wrappedAsset = bridge.wrappedAsset(
            ethereumChainId,
            addressToBytes32(weth)
        );
        uint8 tokenDecimals = getDecimals(wrappedAsset);

        // encode the message by calling the encodePayload method
        bytes memory encodedTransferWithRelay = avaxRelayer.encodeTransferWithRelay(
            ITokenBridgeRelayer.TransferWithRelay({
                payloadId: 1,
                targetRelayerFee: normalizeAmount(relayerFee, tokenDecimals),
                toNativeTokenAmount: normalizeAmount(
                    toNativeTokenAmount,
                    tokenDecimals
                ),
                targetRecipient: addressToBytes32(avaxRecipient)
            })
        );

        // Create a simulated version of the wormhole message that the
        // relayer contract will emit.
        ITokenBridge.TransferWithPayload memory transfer =
            ITokenBridge.TransferWithPayload({
                payloadID: uint8(3), // payload3 transfer
                amount: normalizeAmount(amount, tokenDecimals),
                tokenAddress: addressToBytes32(weth),
                tokenChain: ethereumChainId,
                to: addressToBytes32(address(avaxRelayer)),
                toChain: avaxRelayer.chainId(),
                fromAddress: addressToBytes32(address(this)),
                payload: encodedTransferWithRelay
            });

        // Encode the TransferWithPayload struct and simulate signing
        // the message with the devnet guardian key.
        bytes memory signedMessage = getTransferWithPayloadMessage(
            transfer,
            ethereumChainId,
            addressToBytes32(ethereumTokenBridge)
        );

        // register the token
        avaxRelayer.registerToken(avaxRelayer.chainId(), wrappedAsset);

        // register this contract as the foreign emitter
        avaxRelayer.registerContract(
            ethereumChainId,
            addressToBytes32(address(this))
        );

        // set the native swap rate (so the native gas query works)
        avaxRelayer.updateNativeSwapRate(
            avaxRelayer.chainId(),
            wrappedAsset,
            1 * avaxRelayer.nativeSwapRatePrecision() // swap rate
        );

        // set the max to native amount
        avaxRelayer.updateMaxNativeSwapAmount(
            avaxRelayer.chainId(),
            wrappedAsset,
            6.9e18 // max native swap amount
        );

        // expect the completeTransferWithRelay call to fail
        vm.expectRevert("insufficient native asset amount");
        avaxRelayer.completeTransferWithRelay{value: 0}(signedMessage);
    }
}
