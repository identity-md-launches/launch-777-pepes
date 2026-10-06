// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pepes} from "../src/Pepes.sol";

/// @dev All reachable holders are tracked. No cheatcode ever edits token storage or balances.
contract PepesHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Pepes public immutable token;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E)];
    // Independent ledger: initialized from the allocation and changed only by successful inputs.
    // Never copy observed balances/allowances into the expected state.
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(Pepes token_) {
        token = token_;
        expectedBalance[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordMovement(from, to, amount);
        _assertMovement(from, to, beforeFrom, beforeTo, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        // Reach revocation, unlimited approval, exhaustible approval and arbitrary uint256 values.
        uint256 mode = amount % 4;
        if (mode == 0) amount = 0;
        else if (mode == 1) amount = type(uint256).max;
        else if (mode == 2) amount = bound(amount, 0, SUPPLY);
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(owner);
        uint256 beforeTo = token.balanceOf(to);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, 0, balance < allowed ? balance : allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _recordMovement(owner, to, amount);
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _assertMovement(owner, to, beforeFrom, beforeTo, amount);
        assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
    }

    function transferExceedsBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        amount = bound(amount, balance + 1, type(uint256).max);
        _expectRevert(
            from,
            abi.encodeCall(token.transfer, (to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
        );
    }

    function transferFromExceedsAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        external
    {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[owner][spender];
        // Unlimited approval cannot be exceeded; revoke it explicitly instead of skipping the call.
        if (allowed == type(uint256).max) {
            _approve(owner, spender, 0);
            allowed = 0;
        }
        amount = bound(amount, allowed + 1, type(uint256).max);
        _expectRevert(
            spender,
            abi.encodeCall(token.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
    }

    function transferFromExceedsBalance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amount,
        bool infiniteApproval
    ) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[owner];
        amount = bound(amount, balance + 1, type(uint256).max - 1);
        _approve(owner, spender, infiniteApproval ? type(uint256).max : amount);
        // The failed transfer must roll back any attempted finite allowance consumption.
        _expectRevert(
            spender,
            abi.encodeCall(token.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
    }

    function transferToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool delegated) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[owner]);
        bytes memory expectedError = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        if (delegated) {
            _approve(owner, spender, amount);
            _expectRevert(spender, abi.encodeCall(token.transferFrom, (owner, address(0), amount)), expectedError);
        } else {
            _expectRevert(owner, abi.encodeCall(token.transfer, (address(0), amount)), expectedError);
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        _expectRevert(
            owner,
            abi.encodeCall(token.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount);
    }

    function _recordMovement(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _expectRevert(address caller, bytes memory data, bytes memory expectedError) private {
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(data);
        assertFalse(success, "invalid operation succeeded");
        assertEq(result, expectedError, "unexpected failure reason");
        // Leave the ghost ledger unchanged. The invariants verify all balances and allowances,
        // including unrelated account pairs, after each successful or rejected handler action.
    }

    function _assertMovement(address from, address to, uint256 beforeFrom, uint256 beforeTo, uint256 amount)
        private
        view
    {
        if (from == to) {
            assertEq(token.balanceOf(from), beforeFrom);
        } else {
            assertEq(token.balanceOf(from), beforeFrom - amount);
            assertEq(token.balanceOf(to), beforeTo + amount);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract PepesInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Pepes private token;
    PepesHandler private handler;

    function setUp() public {
        token = new Pepes();
        handler = new PepesHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PepesHandler.transfer.selector;
        selectors[1] = PepesHandler.approve.selector;
        selectors[2] = PepesHandler.transferFrom.selector;
        selectors[3] = PepesHandler.transferExceedsBalance.selector;
        selectors[4] = PepesHandler.transferFromExceedsAllowance.selector;
        selectors[5] = PepesHandler.transferFromExceedsBalance.selector;
        selectors[6] = PepesHandler.transferToZero.selector;
        selectors[7] = PepesHandler.approveZeroSpender.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyIsAlwaysFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_BalancesAndAllowancesMatchAuthorizedOperations() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.balanceOf(owner), handler.expectedBalance(owner), "unauthorized balance change");
            assertEq(token.allowance(owner, address(0)), 0, "zero spender gained allowance");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender), handler.expectedAllowance(owner, spender), "allowance diverged"
                );
            }
        }
    }

    function invariant_AllTokensRemainWithTrackedHolders() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
