// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezToken} from "../src/DeezToken.sol";

contract DeezTokenTest is Test {
    DeezToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000);
        token = new DeezToken(address(this));
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "IMDeezNutz");
        assertEq(token.symbol(), "DEEZ");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27, "whole supply minted to the deployer");
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
        assertEq(token.clock(), 1_000_000);
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 1_000 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromRespectsAllowance() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 4 ether);
        assertEq(token.balanceOf(bob), 4 ether);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
    }

    function test_noMintOwnerOrPause() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "pause()",
            "transferOwnership(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function test_pastBalancesFollowTransfers() public {
        // t = 1_000_000: deployer holds everything.
        vm.warp(1_000_100);
        token.transfer(alice, 100 ether);
        vm.warp(1_000_200);
        token.transfer(alice, 50 ether);
        vm.prank(alice);
        token.transfer(bob, 20 ether);
        vm.warp(1_000_300);

        assertEq(token.getPastBalanceOf(alice, 999_999), 0);
        assertEq(token.getPastBalanceOf(alice, 1_000_099), 0);
        assertEq(token.getPastBalanceOf(alice, 1_000_100), 100 ether);
        assertEq(token.getPastBalanceOf(alice, 1_000_199), 100 ether);
        assertEq(token.getPastBalanceOf(alice, 1_000_200), 130 ether, "same-second moves collapse to the final balance");
        assertEq(token.getPastBalanceOf(alice, 1_000_299), 130 ether);
        assertEq(token.getPastBalanceOf(bob, 1_000_199), 0);
        assertEq(token.getPastBalanceOf(bob, 1_000_200), 20 ether);
        assertEq(token.getPastBalanceOf(address(this), 1_000_000), 1e27);
        assertEq(token.getPastBalanceOf(address(this), 1_000_250), 1e27 - 150 ether);
        assertEq(token.numCheckpoints(alice), 2);
        (uint48 at, uint256 bal, uint256 cumulative) = token.checkpointAt(alice, 1);
        assertEq(at, 1_000_200);
        assertEq(bal, 130 ether);
        assertEq(cumulative, uint256(100 ether) * 100 / 1 days, "100 DEEZ for 100 seconds, in wei-days");
    }

    function test_cumulativeBalanceIntegratesHoldingTime() public {
        // Deployed at t = 1_000_000 with the whole supply.
        vm.warp(1_000_000 + 1 days);
        token.transfer(alice, 100 ether); // alice holds 100 from day 1 on
        vm.warp(1_000_000 + 2 days);
        token.transfer(alice, 100 ether); // 200 from day 2 on
        vm.warp(1_000_000 + 3 days);
        vm.prank(alice);
        token.transfer(bob, 200 ether); // 0 from day 3 on
        vm.warp(1_000_000 + 4 days);

        uint256 t0 = 1_000_000;
        assertEq(token.getCumulativeBalanceOf(alice, t0), 0);
        assertEq(token.getCumulativeBalanceOf(alice, t0 + 1 days), 0, "nothing held before day 1");
        assertEq(token.getCumulativeBalanceOf(alice, t0 + 2 days), 100 ether, "100 for one day");
        assertEq(token.getCumulativeBalanceOf(alice, t0 + 3 days), 300 ether, "plus 200 for one day");
        assertEq(token.getCumulativeBalanceOf(alice, t0 + 4 days), 300 ether, "nothing since day 3");
        assertEq(token.getCumulativeBalanceOf(alice, t0 + 2 days + 12 hours), 200 ether, "half a day at 200");
        assertEq(token.getCumulativeBalanceOf(bob, t0 + 4 days), 200 ether);
        // The average balance over day 2 is the difference of the cumulatives at its ends.
        uint256 start = t0 + 2 days;
        assertEq(
            token.getCumulativeBalanceOf(alice, start + 1 days) - token.getCumulativeBalanceOf(alice, start), 200 ether
        );
        // The deployer held everything until its transfers; total supply integrates from the mint.
        assertEq(token.mintedAt(), t0);
        assertEq(token.getCumulativeTotalSupply(t0), 0);
        assertEq(token.getCumulativeTotalSupply(t0 + 4 days), 4 * 1e27);
        assertEq(
            token.getCumulativeBalanceOf(address(this), t0 + 4 days) + token.getCumulativeBalanceOf(alice, t0 + 4 days)
                + token.getCumulativeBalanceOf(bob, t0 + 4 days),
            token.getCumulativeTotalSupply(t0 + 4 days),
            "the cumulatives of all holders add up to the cumulative supply"
        );
    }

    function test_cumulativeBalanceAllowsTheCurrentSecondButNotTheFuture() public view {
        assertEq(token.getCumulativeBalanceOf(address(this), 1_000_000), 0, "the current second is not counted yet");
    }

    function test_cumulativeBalanceRefusesTheFuture() public {
        vm.expectRevert(abi.encodeWithSelector(DeezToken.FutureLookup.selector, uint48(1_000_001), uint48(1_000_000)));
        token.getCumulativeBalanceOf(alice, 1_000_001);
        vm.expectRevert(abi.encodeWithSelector(DeezToken.FutureLookup.selector, uint48(1_000_001), uint48(1_000_000)));
        token.getCumulativeTotalSupply(1_000_001);
    }

    function testFuzz_cumulativeBalanceMatchesHoldingTime(uint96 a, uint32 gap1, uint32 gap2) public {
        a = uint96(bound(a, 1, 1e27 / 2));
        gap1 = uint32(bound(gap1, 1, 365 days));
        gap2 = uint32(bound(gap2, 1, 365 days));
        uint256 t1 = 2_000_000;
        vm.warp(t1);
        token.transfer(alice, a);
        vm.warp(t1 + gap1);
        vm.prank(alice);
        token.transfer(bob, a);
        vm.warp(t1 + gap1 + gap2);
        uint256 expected = uint256(a) * gap1 / 1 days;
        assertEq(token.getCumulativeBalanceOf(alice, t1 + gap1 + gap2), expected, "a for gap1 seconds");
        assertEq(token.getCumulativeBalanceOf(bob, t1 + gap1 + gap2), uint256(a) * gap2 / 1 days);
    }

    function test_pastBalanceRefusesTheCurrentSecondAndTheFuture() public {
        vm.expectRevert(abi.encodeWithSelector(DeezToken.FutureLookup.selector, uint48(1_000_000), uint48(1_000_000)));
        token.getPastBalanceOf(alice, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(DeezToken.FutureLookup.selector, uint48(1_000_001), uint48(1_000_000)));
        token.getPastBalanceOf(alice, 1_000_001);
    }

    function testFuzz_pastBalanceMatchesBalanceAtThatTime(uint96 a, uint96 b, uint32 gap) public {
        a = uint96(bound(a, 0, 1e27 / 2));
        b = uint96(bound(b, 0, 1e27 / 2));
        gap = uint32(bound(gap, 1, 365 days));
        uint256 t1 = 2_000_000;
        vm.warp(t1);
        token.transfer(alice, a);
        vm.warp(t1 + gap);
        token.transfer(alice, b);
        vm.warp(t1 + gap + 1);
        assertEq(token.getPastBalanceOf(alice, t1), a);
        assertEq(token.getPastBalanceOf(alice, t1 + gap - 1), a);
        assertEq(token.getPastBalanceOf(alice, t1 + gap), uint256(a) + b);
    }
}
