// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Test, console} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract RebaseTokenTest is Test {
    RebaseToken private rebaseToken;
    Vault private vault;
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    function setUp() public {
        vm.startPrank(owner);
        rebaseToken = new RebaseToken();
        vault = new Vault(IRebaseToken(address(rebaseToken)));
        rebaseToken.grantMintAndBurnRole(address(vault));
        vm.stopPrank();
    }

    function addRewardsToVault(uint256 rewardAmount) public {
        (bool success,) = payable(address(vault)).call{value: rewardAmount}("");
    }

    function testDepositLinear(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);
        vm.startPrank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();
        uint256 startBalance = rebaseToken.balanceOf(user);
        console.log("Start Balance:", startBalance);
        assertEq(startBalance, amount);
        vm.warp(block.timestamp + 1 hours);
        uint256 middleBalance = rebaseToken.balanceOf(user);
        console.log("Middle Balance:", middleBalance);
        assertGt(middleBalance, startBalance);
        vm.warp(block.timestamp + 1 hours);
        uint256 endBalance = rebaseToken.balanceOf(user);
        console.log("End Balance:", endBalance);
        assertGt(endBalance, middleBalance);
        assertApproxEqAbs(endBalance - middleBalance, middleBalance - startBalance, 1);
        vm.stopPrank();
    }

    function testRedeemStraightAway(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);
        vm.startPrank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();
        assertEq(rebaseToken.balanceOf(user), amount);
        vault.redeem(type(uint256).max);
        assertEq(rebaseToken.balanceOf(user), 0);
        assertEq(address(user).balance, amount);
        vm.stopPrank();
    }

    function testRedeemAfterTimePassed(uint256 depositAmount, uint256 time) public {
        time = bound(time, 1000, type(uint96).max);
        depositAmount = bound(depositAmount, 1e5, type(uint96).max);

        vm.prank(user);
        vm.deal(user, depositAmount);
        vault.deposit{value: depositAmount}();
        vm.warp(block.timestamp + time);
        uint256 balanceAfterSomeTime = rebaseToken.balanceOf(user);
        vm.deal(owner, balanceAfterSomeTime - depositAmount);
        vm.prank(owner);
        addRewardsToVault(balanceAfterSomeTime - depositAmount);
        vm.prank(user);
        vault.redeem(type(uint256).max);
        uint256 ethBalance = address(user).balance;
        assertEq(ethBalance, balanceAfterSomeTime);
        assertGt(ethBalance, depositAmount);
    }

    function testTransfer(uint256 amount, uint256 amountToSend) public {
        amount = bound(amount, 1e5 + 1, type(uint96).max);
        amountToSend = bound(amountToSend, 1e5 - 1, amount - 1);
        vm.prank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();
        address user2 = makeAddr("user2");
        uint256 userStartingBalance = rebaseToken.balanceOf(user);
        uint256 user2StartingBalance = rebaseToken.balanceOf(user2);
        assertEq(userStartingBalance, amount);
        assertEq(user2StartingBalance, 0);

        vm.prank(owner);
        rebaseToken.setInterestRate(4e10);

        vm.prank(user);
        rebaseToken.transfer(user2, amountToSend);
        uint256 userBalanceAfterTransfer = rebaseToken.balanceOf(user);
        uint256 user2BalanceAfterTransfer = rebaseToken.balanceOf(user2);
        assertEq(userBalanceAfterTransfer, userStartingBalance - amountToSend);
        assertEq(user2BalanceAfterTransfer, amountToSend);

        assertEq(rebaseToken.getUserInterestRate(user), 5e10);
        assertEq(rebaseToken.getUserInterestRate(user2), 5e10);
    }

    function testCantSetInterestRateIfNotOwner(uint256 newRate) public {
        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        rebaseToken.setInterestRate(newRate);
    }

    function testCantCallMintAndBurnIfNotRole() public {
        vm.prank(user);
        uint256 interestRate = rebaseToken.getInterestRate();
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        rebaseToken.mint(user, 100, interestRate);
        vm.prank(user);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        rebaseToken.burn(user, 100);
    }

    function testGetPrincipalAmount(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);
        vm.prank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();
        assertEq(rebaseToken.principalBalanceOf(user), amount);

        vm.warp(block.timestamp + 1 weeks);
        assertEq(rebaseToken.principalBalanceOf(user), amount);
    }

    function testGetRebaseTokenAddress() public view {
        assertEq(vault.getRebaseTokenAddress(), address(rebaseToken));
    }

    function testInterestRateCanOnlyDecrease(uint256 newRate) public {
        uint256 initialInterestRate = rebaseToken.getInterestRate();
        newRate = bound(newRate, initialInterestRate, type(uint96).max);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                RebaseToken.RebaseToken__InterestRateCanOnlyDecrease.selector, initialInterestRate, newRate
            )
        );
        rebaseToken.setInterestRate(newRate);
        assertEq(rebaseToken.getInterestRate(), initialInterestRate);
    }
}
