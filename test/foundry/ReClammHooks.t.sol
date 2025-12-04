// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { PoolHooksMock } from "@balancer-labs/v3-vault/contracts/test/PoolHooksMock.sol";

import { ReClammPoolImmutableData } from "../../contracts/interfaces/IReClammPoolExtension.sol";
import { IReClammPool } from "../../contracts/interfaces/IReClammPool.sol";
import { ReClammCommon } from "../../contracts/ReClammCommon.sol";
import { ReClammPool } from "../../contracts/ReClammPool.sol";
import { BaseReClammTest } from "./utils/BaseReClammTest.sol";

contract ReClammHookTest is BaseReClammTest {
    using ArrayHelpers for *;

    function testAllHooksEnabled() public view {
        _checkHookFlags(pool);
    }

    function testOnRegisterForwarding() public {
        // This should cause registration to fail.
        PoolHooksMock(poolHooksContract).denyFactory(poolFactory);

        LiquidityManagement memory liquidityManagement;

        vm.prank(address(vault));
        bool success = IHooks(pool).onRegister(address(this), address(this), new TokenConfig[](2), liquidityManagement);
        assertFalse(success, "onRegister did not fail");
    }

    function testNoHook() public {
        poolHooksContract = address(0);

        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));

        ReClammPoolImmutableData memory data = IReClammPool(newPool).getReClammPoolImmutableData();
        assertEq(data.hookContract, address(0), "Pool has a hook");

        PoolSwapParams memory params;

        // Try to call an unsupported hook.
        vm.expectRevert(ReClammCommon.NotImplemented.selector);
        vm.prank(address(vault));
        IHooks(newPool).onBeforeSwap(params, address(newPool));
    }

    function testOnBeforeInitializeForwarding() public {
        // OnInitialize should succeed.
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        uint256 snapshotId = vm.snapshotState();

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnBeforeInitializeHook(true);

        vm.expectRevert(IVaultErrors.BeforeInitializeHookFailed.selector);
        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));
    }

    function testOnAfterInitializeForwarding() public {
        // OnInitialize should succeed (forwards to a no-op).
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        uint256 snapshotId = vm.snapshotState();

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnAfterInitializeHook(true);

        vm.expectRevert(IVaultErrors.AfterInitializeHookFailed.selector);
        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));
    }

    function testOnBeforeAddLiquidityForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        uint256 exactBptAmountOut = 100e18;

        uint256 snapshotId = vm.snapshotState();

        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnBeforeAddLiquidityHook(true);

        vm.expectRevert(IVaultErrors.BeforeAddLiquidityHookFailed.selector);
        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");
    }

    function testOnAfterAddLiquidityForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        _checkHookFlags(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, bytes(""));

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[daiIdx] = dai.balanceOf(alice);
        maxAmountsIn[usdcIdx] = usdc.balanceOf(alice);

        uint256 exactBptAmountOut = 100e18;

        uint256 snapshotId = vm.snapshotState();

        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnAfterAddLiquidityHook(true);

        vm.expectRevert(IVaultErrors.AfterAddLiquidityHookFailed.selector);
        vm.prank(alice);
        router.addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, "");
    }

    function testOnBeforeRemoveLiquidityForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, "");

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;
        uint256 exactBptAmountIn = IERC20(newPool).balanceOf(alice) / 10;

        uint256 snapshotId = vm.snapshotState();

        vm.prank(alice);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnBeforeRemoveLiquidityHook(true);

        vm.expectRevert(IVaultErrors.BeforeRemoveLiquidityHookFailed.selector);
        vm.prank(alice);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");
    }

    function testOnAfterRemoveLiquidityForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, "");

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[daiIdx] = 0;
        minAmountsOut[usdcIdx] = 0;
        uint256 exactBptAmountIn = IERC20(newPool).balanceOf(alice) / 10;

        uint256 snapshotId = vm.snapshotState();

        vm.prank(alice);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnAfterRemoveLiquidityHook(true);

        vm.expectRevert(IVaultErrors.AfterRemoveLiquidityHookFailed.selector);
        vm.prank(alice);
        router.removeLiquidityProportional(pool, exactBptAmountIn, minAmountsOut, false, "");
    }

    function testOnBeforeSwapForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, "");

        uint256 snapshotId = vm.snapshotState();

        uint256 amountDaiIn = 100e18;

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnBeforeSwapHook(true);

        vm.expectRevert(IVaultErrors.BeforeSwapHookFailed.selector);
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));
    }

    function testOnAfterSwapForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, "");

        uint256 snapshotId = vm.snapshotState();

        uint256 amountDaiIn = 100e18;

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnAfterSwapHook(true);

        vm.expectRevert(IVaultErrors.AfterSwapHookFailed.selector);
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));
    }

    function testOnComputeDynamicSwapFeeForwarding() public {
        (address newPool, ) = _createPool([address(usdc), address(dai)].toMemoryArray(), "New Test Pool");
        (IERC20[] memory tokens, , , ) = vault.getPoolTokenInfo(newPool);

        vm.prank(bob);
        router.initialize(newPool, tokens, _initialBalances, 0, false, "");

        uint256 snapshotId = vm.snapshotState();

        uint256 amountDaiIn = 100e18;

        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));

        vm.revertToState(snapshotId);

        // Now the forwarded hook should make it fail.
        PoolHooksMock(poolHooksContract).setFailOnComputeDynamicSwapFeeHook(true);

        vm.expectRevert(IVaultErrors.DynamicSwapFeeHookFailed.selector);
        vm.prank(alice);
        router.swapSingleTokenExactIn(pool, dai, usdc, amountDaiIn, 0, MAX_UINT256, false, bytes(""));
    }

    function _checkHookFlags(address pool) internal view {
        HookFlags memory hookFlags = ReClammPool(payable(pool)).getHookFlags();

        assertFalse(hookFlags.enableHookAdjustedAmounts, "enableHookAdjustedAmounts is true");
        assertTrue(hookFlags.shouldCallBeforeInitialize, "shouldCallBeforeInitialize is false");
        assertTrue(hookFlags.shouldCallAfterInitialize, "shouldCallAfterInitialize is false");
        assertTrue(hookFlags.shouldCallComputeDynamicSwapFee, "shouldCallComputeDynamicSwapFee is false");
        assertTrue(hookFlags.shouldCallBeforeSwap, "shouldCallBeforeSwap is false");
        assertTrue(hookFlags.shouldCallAfterSwap, "shouldCallAfterSwap is false");
        assertTrue(hookFlags.shouldCallBeforeAddLiquidity, "shouldCallBeforeAddLiquidity is false");
        assertTrue(hookFlags.shouldCallAfterAddLiquidity, "shouldCallAfterAddLiquidity is false");
        assertTrue(hookFlags.shouldCallBeforeRemoveLiquidity, "shouldCallBeforeRemoveLiquidity is false");
        assertTrue(hookFlags.shouldCallAfterRemoveLiquidity, "shouldCallAfterRemoveLiquidity is false");
    }
}
