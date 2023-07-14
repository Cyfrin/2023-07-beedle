// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Lender.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract TERC20 is ERC20 {

    function name() public pure override returns (string memory) {
        return "Test ERC20";
    }

    function symbol() public pure override returns (string memory) {
        return "TERC20";
    }

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }
}

contract LenderTest is Test {
    Lender public lender;

    TERC20 public loanToken;
    TERC20 public collateralToken;

    address public lender1 = address(0x1);
    address public lender2 = address(0x2);
    address public borrower = address(0x3);
    address public fees = address(0x4);

    function setUp() public {
        lender = new Lender();
        loanToken = new TERC20();
        collateralToken = new TERC20();
        loanToken.mint(address(lender1), 100000*10**18);
        loanToken.mint(address(lender2), 100000*10**18);
        loanToken.mint(address(borrower), 100000*10**18);
        collateralToken.mint(address(borrower), 100000*10**18);
        vm.startPrank(lender1);
        loanToken.approve(address(lender), 1000000*10**18);
        collateralToken.approve(address(lender), 1000000*10**18);
        vm.startPrank(lender2);
        loanToken.approve(address(lender), 1000000*10**18);
        collateralToken.approve(address(lender), 1000000*10**18);
        vm.startPrank(borrower);
        loanToken.approve(address(lender), 1000000*10**18);
        collateralToken.approve(address(lender), 1000000*10**18);
    }

    function testFuzz_createPool(uint256 amount, uint256 auctionLength) public {
        vm.startPrank(lender1);
        Pool memory p = Pool({
            lender: lender1,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: amount,
            maxLoanRatio: 2*10**18,
            auctionLength: auctionLength,
            interestRate: 1000,
            outstandingLoans: 0
        });
        if (amount > loanToken.balanceOf(address(lender1))) {
            vm.expectRevert();
            lender.setPool(p);
        } else if (auctionLength > lender.MAX_AUCTION_LENGTH()) {
            vm.expectRevert(PoolConfig.selector);
            lender.setPool(p);
        } else if (auctionLength == 0) {
            vm.expectRevert(PoolConfig.selector);
            lender.setPool(p);
        } else {
            lender.setPool(p);

            bytes32 poolId = keccak256(
                abi.encode(
                    address(lender1),
                    address(loanToken),
                    address(collateralToken)
                )
            );

            (,,,,uint256 poolBalance,,,,) = lender.pools(poolId);
            assertEq(poolBalance, amount);
        }
    }

    function testFuzz_borrow(uint256 debtAmount, uint256 collateralAmount) public {
        vm.assume(collateralAmount < 100000*10**18);
        vm.assume(collateralAmount > 0);
        vm.startPrank(lender1);
        Pool memory p = Pool({
            lender: lender1,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        bytes32 poolId = lender.setPool(p);

        vm.startPrank(borrower);
        Borrow memory b = Borrow({
            poolId: poolId,
            debt: debtAmount,
            collateral: collateralAmount
        });
        Borrow[] memory borrows = new Borrow[](1);
        borrows[0] = b;

        if (debtAmount > 1000*10**18) {
            vm.expectRevert(LoanTooLarge.selector);
            lender.borrow(borrows);
        } else if (debtAmount < 100*10**18) {
            vm.expectRevert(LoanTooSmall.selector);
            lender.borrow(borrows);
        } else if (debtAmount > collateralAmount*2) {
            vm.expectRevert(RatioTooHigh.selector);
            lender.borrow(borrows);
        } else {
            lender.borrow(borrows);
            assertEq(loanToken.balanceOf(address(borrower)), debtAmount);
            assertEq(collateralToken.balanceOf(address(lender)), collateralAmount);
            (,,,,uint256 poolBalance,,,,) = lender.pools(poolId);
            assertEq(poolBalance, 1000*10**18 - debtAmount);
        }
    }

    function testFuzz_repay(uint256 loanLength) public {
        vm.assume(loanLength < 1500 days);
        vm.startPrank(lender1);
        Pool memory p = Pool({
            lender: lender1,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        bytes32 poolId = lender.setPool(p);

        (,,,,uint256 poolBalance,,,,) = lender.pools(poolId);
        assertEq(poolBalance, 1000*10**18);

        vm.startPrank(borrower);
        Borrow memory b = Borrow({
            poolId: poolId,
            debt: 100*10**18,
            collateral: 100*10**18
        });
        Borrow[] memory borrows = new Borrow[](1);
        borrows[0] = b;
        lender.borrow(borrows);

        vm.warp(block.timestamp + loanLength);

        uint256 debt = lender.getLoanDebt(0);
        uint256 interest = ((p.interestRate * b.debt * loanLength) / 10000 / 365 days);
        uint256 f = (lender.lenderFee() * interest) / 10000;
        interest -= f;

        loanToken.mint(address(borrower), 5*10**17);
        uint256[] memory loanIds = new uint256[](1);
        loanIds[0] = 0;
        lender.repay(loanIds);

        assertEq(loanToken.balanceOf(address(borrower)), 100000*10**18 - interest - f);
        assertEq(collateralToken.balanceOf(address(lender)), 0);
        (,,,,poolBalance,,,,) = lender.pools(poolId);
        assertEq(poolBalance, 1000*10**18 + interest);
    }

    // /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    // /*                         AUCTIONS                           */
    // /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_buyLoan(uint256 timeToBuy) public {
        vm.assume(timeToBuy < 1500 days);
        vm.startPrank(lender1);
        Pool memory p = Pool({
            lender: lender1,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        bytes32 poolId = lender.setPool(p);

        (,,,,uint256 poolBalance,,,,) = lender.pools(poolId);
        assertEq(poolBalance, 1000*10**18);

        vm.startPrank(borrower);
        Borrow memory b = Borrow({
            poolId: poolId,
            debt: 100*10**18,
            collateral: 100*10**18
        });
        Borrow[] memory borrows = new Borrow[](1);
        borrows[0] = b;
        lender.borrow(borrows);

        // kick off auction
        vm.startPrank(lender1);

        uint256[] memory loanIds = new uint256[](1);
        loanIds[0] = 0;

        lender.startAuction(loanIds);

        vm.startPrank(lender2);
        Pool memory p2 = Pool({
            lender: lender2,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        bytes32 p2ID = lender.setPool(p2);

        vm.warp(block.timestamp + timeToBuy);

        uint256 maxInterest = (lender.MAX_INTEREST_RATE() * timeToBuy) / p.auctionLength;

        if (timeToBuy > 1 days) {
            vm.expectRevert(AuctionEnded.selector);
            lender.buyLoan(0, p2ID);
        } else if (maxInterest < p2.interestRate) {
            vm.expectRevert(RateTooHigh.selector);
            lender.buyLoan(0, p2ID);
        } else {
            lender.buyLoan(0, p2ID);
        }
    }

    function testFuzz_seize(uint256 timeToWait) public {
        vm.assume(timeToWait < 1500 days);
        vm.startPrank(lender1);
        Pool memory p = Pool({
            lender: lender1,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        bytes32 poolId = lender.setPool(p);

        (,,,,uint256 poolBalance,,,,) = lender.pools(poolId);
        assertEq(poolBalance, 1000*10**18);

        vm.startPrank(borrower);
        Borrow memory b = Borrow({
            poolId: poolId,
            debt: 100*10**18,
            collateral: 100*10**18
        });
        Borrow[] memory borrows = new Borrow[](1);
        borrows[0] = b;
        lender.borrow(borrows);

        // kick off auction
        vm.startPrank(lender1);

        uint256[] memory loanIds = new uint256[](1);
        loanIds[0] = 0;

        lender.startAuction(loanIds);

        vm.warp(block.timestamp + timeToWait);

        if (timeToWait < 1 days) {
            vm.expectRevert(AuctionNotEnded.selector);
            lender.seizeLoan(loanIds);
        } else {
            lender.seizeLoan(loanIds);
        }
    }

    // /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    // /*                         REFINANCE                          */
    // /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_refinance(uint256 debt, uint256 collateral) public {
        vm.assume(debt < 100000*10**18);
        vm.assume(debt > 0);
        vm.assume(collateral < 100000*10**18);
        vm.assume(collateral > 0);
        vm.startPrank(lender1);
        Pool memory p = Pool({
            lender: lender1,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        bytes32 poolId = lender.setPool(p);

        (,,,,uint256 poolBalance,,,,) = lender.pools(poolId);
        assertEq(poolBalance, 1000*10**18);

        vm.startPrank(borrower);
        Borrow memory b = Borrow({
            poolId: poolId,
            debt: 100*10**18,
            collateral: 100*10**18
        });
        Borrow[] memory borrows = new Borrow[](1);
        borrows[0] = b;
        lender.borrow(borrows);

        vm.startPrank(lender2);
        Pool memory p2 = Pool({
            lender: lender2,
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            minLoanSize: 100*10**18,
            poolBalance: 1000*10**18,
            maxLoanRatio: 2*10**18,
            auctionLength: 1 days,
            interestRate: 1000,
            outstandingLoans: 0
        });
        lender.setPool(p2);

        vm.startPrank(borrower);
        Refinance memory r = Refinance({
            loanId: 0,
            poolId: keccak256(
                abi.encode(
                    address(lender2),
                    address(loanToken),
                    address(collateralToken)
                )
            ),
            debt: debt,
            collateral: collateral
        });
        Refinance[] memory rs = new Refinance[](1);
        rs[0] = r;

        if (debt > 1000*10**18) {
            vm.expectRevert(LoanTooLarge.selector);
            lender.refinance(rs);
        } else if (debt < 100*10**18) {
            vm.expectRevert(LoanTooSmall.selector);
            lender.refinance(rs);
        } else if (debt > collateral*2) {
            vm.expectRevert(RatioTooHigh.selector);
            lender.refinance(rs);
        } else {
            lender.refinance(rs);
        }

    }

}