// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pepes} from "../src/Pepes.sol";

/// @dev Test-only factory exercising constructor ownership under CREATE2.
contract PepesFactoryFixture {
    function deploy(bytes32 salt) external returns (Pepes) {
        return new Pepes{salt: salt}();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract PepesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant DEPLOYER = address(0xD3E10);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);

    Pepes private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new Pepes();
    }

    function test_MetadataAndEntireInitialSupply() public view {
        assertEq(token.name(), "Pepes");
        assertEq(token.symbol(), "PEPES");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
    }

    function test_ConstructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(ALICE);
        Pepes fresh = new Pepes();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(ALICE))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_Create2FactoryReceivesEntireSupplyAndLaunchTransfersAreExact() public {
        PepesFactoryFixture factory = new PepesFactoryFixture();
        bytes32 salt = keccak256("Pepes fixture");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(Pepes).creationCode))
                    )
                )
            )
        );
        vm.prank(ALICE);
        Pepes launched = factory.deploy(salt);
        assertEq(address(launched), predicted);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(ALICE), 0);

        address distributor = address(0xD157);
        address poolManager = address(0x9001);
        uint256 swarm = SUPPLY / 10;
        uint256 seed = SUPPLY / 2; // Illustrative test allocation, not deployment economics.
        vm.startPrank(address(factory));
        assertTrue(launched.transfer(distributor, swarm));
        assertTrue(launched.transfer(poolManager, seed));
        assertTrue(launched.transfer(ALICE, SUPPLY - swarm - seed));
        vm.stopPrank();
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), seed);
        assertEq(launched.balanceOf(ALICE), SUPPLY - swarm - seed);

        vm.prank(distributor);
        assertTrue(launched.transfer(BOB, swarm));
        assertEq(launched.balanceOf(BOB), swarm);
        assertEq(launched.balanceOf(distributor), 0);
        vm.prank(poolManager);
        assertTrue(launched.transfer(SPENDER, 100 ether));
        assertEq(launched.balanceOf(SPENDER), 100 ether);
        vm.prank(SPENDER);
        assertTrue(launched.transfer(poolManager, 100 ether));
        assertEq(launched.balanceOf(SPENDER), 0);
        assertEq(launched.balanceOf(poolManager), seed);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferEmitsEventAndArrivesWithoutFee() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(DEPLOYER, ALICE, 123 ether);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 123 ether));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 123 ether);
        assertEq(token.balanceOf(ALICE), 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEntireBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DEPLOYER, SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveEmitsEventAndDoesNotMoveFunds() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(DEPLOYER, SPENDER, 200 ether);
        _approve(200 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 200 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(SPENDER), 0);
    }

    function test_ApprovalReplacementAndRevocation() public {
        _approve(200 ether);
        _approve(25 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 25 ether);
        _approve(0);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_TransferFromEmitsEventAndConsumesExactAllowance() public {
        _approve(200 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(DEPLOYER, ALICE, 75 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 75 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 125 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 75 ether);
        assertEq(token.balanceOf(ALICE), 75 ether);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromCanExhaustAllowance() public {
        _approve(1 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 1 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function test_MaximumAllowanceIsNotDecremented() public {
        _approve(type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, SUPPLY));
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
    }

    function test_DelegatedSelfTransferConsumesAllowanceWithoutChangingBalance() public {
        _approve(10 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, DEPLOYER, 10 ether));
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_ZeroTransferFromRequiresNoAllowance() public {
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_OneWeiTransfersArriveWhole() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 1));
        assertEq(token.balanceOf(ALICE), 1);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 1));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 1));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumTransferAmountsRevertWithoutChangingState() public {
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, type(uint256).max);
        vm.expectRevert(errorData);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, type(uint256).max);

        _approve(type(uint256).max);
        vm.expectRevert(errorData);
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, type(uint256).max);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumMinusOneAllowanceIsFinite() public {
        _approve(type(uint256).max - 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 1));
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max - 2);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1);
        assertEq(token.balanceOf(ALICE), 1);
    }

    function test_RevokingUnlimitedApprovalPreventsFurtherSpending() public {
        _approve(type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 1));
        _approve(0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_AllowanceStaysWithOwnerWhenTokensMoveAwayAndBack() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 100));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 100));
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(BOB, SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, SPENDER, 1);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        assertEq(token.allowance(BOB, SPENDER), 0);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(token.balanceOf(SPENDER), 0);

        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, 1));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, SPENDER, 1));
        assertEq(token.allowance(ALICE, SPENDER), 99);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 99);
        assertEq(token.balanceOf(SPENDER), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApprovalIsNotTransitive() public {
        _approve(10);
        vm.prank(SPENDER);
        assertTrue(token.approve(BOB, 10));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), 10);
        assertEq(token.allowance(SPENDER, BOB), 10);
        assertEq(token.allowance(DEPLOYER, BOB), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_OwnerCallingTransferFromNeedsItsOwnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, ALICE, 1);
        vm.prank(DEPLOYER);
        assertTrue(token.approve(DEPLOYER, 1));
        vm.prank(DEPLOYER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 1));
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1);
        assertEq(token.balanceOf(ALICE), 1);
    }

    function test_RevertWhenTransferExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY + 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenSelfTransferExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(ALICE, 1);
    }

    function test_RevertWhenTransferToZeroEvenForZeroAmount() public {
        for (uint256 amount; amount < 2; ++amount) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(DEPLOYER);
            token.transfer(address(0), amount);
        }
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenApproveZeroSpender() public {
        uint256[3] memory amounts = [uint256(0), uint256(1), type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            vm.prank(DEPLOYER);
            token.approve(address(0), amounts[i]);
        }
        assertEq(token.allowance(DEPLOYER, address(0)), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenUnapprovedCallerSpendsAnotherHoldersTokens() public {
        _approve(100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), 100 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhenDeployerSpendsHolderTokensWithoutApproval() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(ALICE, DEPLOYER, 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_RevertWhenTransferFromExceedsBalanceRestoresAllowance() public {
        _approve(SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, SUPPLY + 1);
        assertEq(token.allowance(DEPLOYER, SPENDER), SUPPLY + 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenTransferFromToZeroRestoresAllowance() public {
        _approve(10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, address(0), 10 ether);
        assertEq(token.allowance(DEPLOYER, SPENDER), 10 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenTransferFromZeroSender() public {
        // ERC20 checks the allowance owner before reaching the balance transfer.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_NoMintBurnOrAdministrativeEntryPoints() public {
        string[24] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "burn(uint256)",
            "rebase(uint256)"
        ];
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            vm.prank(DEPLOYER);
            (bool fromDeployer,) = address(token).call(data);
            assertFalse(fromDeployer, signatures[i]);
            vm.prank(BOB);
            (bool fromStranger,) = address(token).call(data);
            assertFalse(fromStranger, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(ALICE), 100 ether);
            assertEq(token.balanceOf(DEPLOYER), SUPPLY - 100 ether);
        }
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(BOB), 100 ether);
    }

    function test_RuntimeContainsNoDangerousOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzz_TransferPreservesSupplyAndDeliversExactAmount(address recipient, uint256 amount) public {
        if (recipient == address(0) || recipient == DEPLOYER) recipient = ALICE;
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromDeliversExactAmount(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        _approve(approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, amount));
        assertEq(token.allowance(DEPLOYER, SPENDER), approved - amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_RevertWhenTransferFromExceedsAllowance(uint256 approved, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        approved = bound(approved, 0, amount - 1);
        _approve(approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, approved, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, ALICE, amount);
        assertEq(token.allowance(DEPLOYER, SPENDER), approved);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferRoundTripRestoresAllBalances(uint256 amount, uint256 existingBalance) public {
        existingBalance = bound(existingBalance, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY - existingBalance);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, existingBalance));
        _approve(type(uint256).max);

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), existingBalance + amount);
        vm.prank(ALICE);
        assertTrue(token.transfer(DEPLOYER, amount));
        assertEq(token.balanceOf(ALICE), existingBalance);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - existingBalance);
        assertEq(token.allowance(DEPLOYER, SPENDER), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_ApprovalsAreIdempotentAndIsolated(uint256 first, uint256 replacement, uint256 other) public {
        vm.prank(DEPLOYER);
        assertTrue(token.approve(BOB, other));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, other));
        _approve(first);
        _approve(replacement);
        _approve(replacement);
        assertEq(token.allowance(DEPLOYER, SPENDER), replacement);
        assertEq(token.allowance(DEPLOYER, BOB), other);
        assertEq(token.allowance(ALICE, SPENDER), other);
        assertEq(token.allowance(SPENDER, DEPLOYER), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_FiniteAllowanceCannotBeReplayedAfterSplitSpending(uint256 approved, uint256 first) public {
        approved = bound(approved, 1, SUPPLY);
        first = bound(first, 0, approved);
        _approve(approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, first));
        assertEq(token.allowance(DEPLOYER, SPENDER), approved - first);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(DEPLOYER, BOB, approved - first));
        assertEq(token.allowance(DEPLOYER, SPENDER), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(DEPLOYER, SPENDER, 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - approved);
        assertEq(token.balanceOf(ALICE), first);
        assertEq(token.balanceOf(BOB), approved - first);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_FailedDelegatedTransferDoesNotConsumeApproval(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max - 1);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, balance));
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, amount));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(token.allowance(ALICE, SPENDER), amount);
        assertEq(token.balanceOf(ALICE), balance);
        assertEq(token.balanceOf(BOB), 0);

        // A rejected call must not poison a later valid use of the same approval.
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, balance));
        assertEq(token.allowance(ALICE, SPENDER), amount - balance);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), balance);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - balance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _approve(uint256 amount) private {
        vm.prank(DEPLOYER);
        assertTrue(token.approve(SPENDER, amount));
    }
}
