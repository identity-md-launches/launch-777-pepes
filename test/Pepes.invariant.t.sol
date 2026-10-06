// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pepes} from "../src/Pepes.sol";

/// @dev All reachable holders are tracked. No cheatcode ever edits token storage or balances.
contract PepesHandler is Test {
    Pepes public immutable token;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E)];

    constructor(Pepes token_) {
        token = token_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        amount = bound(amount, 0, beforeFrom);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _assertMovement(from, to, beforeFrom, beforeTo, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(owner);
        uint256 beforeTo = token.balanceOf(to);
        uint256 allowed = token.allowance(owner, spender);
        amount = bound(amount, 0, beforeFrom < allowed ? beforeFrom : allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _assertMovement(owner, to, beforeFrom, beforeTo, amount);
        assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
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

contract PepesInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Pepes private token;
    PepesHandler private handler;

    function setUp() public {
        token = new Pepes();
        handler = new PepesHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PepesHandler.transfer.selector;
        selectors[1] = PepesHandler.approve.selector;
        selectors[2] = PepesHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyIsAlwaysFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
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
