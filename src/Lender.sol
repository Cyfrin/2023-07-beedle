// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./utils/Errors.sol";
import "./utils/Structs.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

contract Lender is Ownable {
    event PoolCreated(bytes32 indexed poolId, Pool pool);
    event PoolUpdated(bytes32 indexed poolId, Pool pool);
    event PoolBalanceUpdated(bytes32 indexed poolId, uint256 newBalance);
    event PoolInterestRateUpdated(
        bytes32 indexed poolId,
        uint256 newInterestRate
    );
    event PoolMaxLoanRatioUpdated(
        bytes32 indexed poolId,
        uint256 newMaxLoanRatio
    );
    event Borrowed(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 debt,
        uint256 collateral,
        uint256 interestRate,
        uint256 startTimestamp
    );
    event Repaid(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 debt,
        uint256 collateral,
        uint256 interestRate,
        uint256 startTimestamp
    );
    event AuctionStart(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 debt,
        uint256 collateral,
        uint256 auctionStartTime,
        uint256 auctionLength
    );
    event LoanBought(uint256 loanId);
    event LoanSiezed(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 collateral
    );
    event Refinanced(uint256 loanId);

    /// @notice the maximum interest rate is 1000%
    uint256 public constant MAX_INTEREST_RATE = 100000;
    /// @notice the maximum auction length is 3 days
    uint256 public constant MAX_AUCTION_LENGTH = 3 days;
    /// @notice the fee taken by the protocol in BIPs
    uint256 public lenderFee = 1000;
    /// @notice the fee taken by the protocol in BIPs
    uint256 public borrowerFee = 50;
    /// @notice the address of the fee receiver
    address public feeReceiver;

    /// @notice mapping of poolId to Pool (poolId is keccak256(lender, loanToken, collateralToken))
    mapping(bytes32 => Pool) public pools;
    Loan[] public loans;

    constructor() Ownable(msg.sender) {
        feeReceiver = msg.sender;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         GOVERNANCE                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice set the lender fee
    /// can only be called by the owner
    /// @param _fee the new fee
    function setLenderFee(uint256 _fee) external onlyOwner {
        if (_fee > 5000) revert FeeTooHigh();
        lenderFee = _fee;
    }

    /// @notice set the borrower fee
    /// can only be called by the owner
    /// @param _fee the new fee
    function setBorrowerFee(uint256 _fee) external onlyOwner {
        if (_fee > 500) revert FeeTooHigh();
        borrowerFee = _fee;
    }

    /// @notice set the fee receiver
    /// can only be called by the owner
    /// @param _feeReceiver the new fee receiver
    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         LOAN INFO                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getPoolId(
        address lender,
        address loanToken,
        address collateralToken
    ) public pure returns (bytes32 poolId) {
        poolId = keccak256(abi.encode(lender, loanToken, collateralToken));
    }

    function getLoanDebt(uint256 loanId) external view returns (uint256 debt) {
        Loan memory loan = loans[loanId];
        // calculate the accrued interest
        (uint256 interest, uint256 fees) = _calculateInterest(loan);
        debt = loan.debt + interest + fees;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        BASIC LOANS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice set the info for a pool
    /// updates pool info for msg.sender
    /// @param p the new pool info
    function setPool(Pool calldata p) public returns (bytes32 poolId) {
        // validate the pool
        if (
            p.lender != msg.sender ||
            p.minLoanSize == 0 ||
            p.maxLoanRatio == 0 ||
            p.auctionLength == 0 ||
            p.auctionLength > MAX_AUCTION_LENGTH ||
            p.interestRate > MAX_INTEREST_RATE
        ) revert PoolConfig();

        // check if they already have a pool balance
        poolId = getPoolId(p.lender, p.loanToken, p.collateralToken);

        // you can't change the outstanding loans
        if (p.outstandingLoans != pools[poolId].outstandingLoans)
            revert PoolConfig();

        uint256 currentBalance = pools[poolId].poolBalance;

        if (p.poolBalance > currentBalance) {
            // if new balance > current balance then transfer the difference from the lender
            IERC20(p.loanToken).transferFrom(
                p.lender,
                address(this),
                p.poolBalance - currentBalance
            );
        } else if (p.poolBalance < currentBalance) {
            // if new balance < current balance then transfer the difference back to the lender
            IERC20(p.loanToken).transfer(
                p.lender,
                currentBalance - p.poolBalance
            );
        }

        emit PoolBalanceUpdated(poolId, p.poolBalance);

        if (pools[poolId].lender == address(0)) {
            // if the pool doesn't exist then create it
            emit PoolCreated(poolId, p);
        } else {
            // if the pool does exist then update it
            emit PoolUpdated(poolId, p);
        }

        pools[poolId] = p;
    }

    /// @notice add to the pool balance
    /// can only be called by the pool lender
    /// @param poolId the id of the pool to add to
    /// @param amount the amount to add
    function addToPool(bytes32 poolId, uint256 amount) external {
        if (pools[poolId].lender != msg.sender) revert Unauthorized();
        if (amount == 0) revert PoolConfig();
        _updatePoolBalance(poolId, pools[poolId].poolBalance + amount);
        // transfer the loan tokens from the lender to the contract
        IERC20(pools[poolId].loanToken).transferFrom(
            msg.sender,
            address(this),
            amount
        );
    }

    /// @notice remove from the pool balance
    /// can only be called by the pool lender
    /// @param poolId the id of the pool to remove from
    /// @param amount the amount to remove
    function removeFromPool(bytes32 poolId, uint256 amount) external {
        if (pools[poolId].lender != msg.sender) revert Unauthorized();
        if (amount == 0) revert PoolConfig();
        _updatePoolBalance(poolId, pools[poolId].poolBalance - amount);
        // transfer the loan tokens from the contract to the lender
        IERC20(pools[poolId].loanToken).transfer(msg.sender, amount);
    }

    /// @notice update the max loan ratio for a pool
    /// can only be called by the pool lender
    /// @param poolId the id of the pool to update
    /// @param maxLoanRatio the new max loan ratio
    function updateMaxLoanRatio(bytes32 poolId, uint256 maxLoanRatio) external {
        if (pools[poolId].lender != msg.sender) revert Unauthorized();
        if (maxLoanRatio == 0) revert PoolConfig();
        pools[poolId].maxLoanRatio = maxLoanRatio;
        emit PoolMaxLoanRatioUpdated(poolId, maxLoanRatio);
    }

    /// @notice update the interest rate for a pool
    /// can only be called by the pool lender
    /// @param poolId the id of the pool to update
    /// @param interestRate the new interest rate
    function updateInterestRate(bytes32 poolId, uint256 interestRate) external {
        if (pools[poolId].lender != msg.sender) revert Unauthorized();
        if (interestRate > MAX_INTEREST_RATE) revert PoolConfig();
        pools[poolId].interestRate = interestRate;
        emit PoolInterestRateUpdated(poolId, interestRate);
    }

    /// @notice borrow a loan from a pool
    /// can be called by anyone
    /// you are allowed to open many borrows at once
    /// @param borrows a struct of all desired debt positions to be opened
    function borrow(Borrow[] calldata borrows) public {
        for (uint256 i = 0; i < borrows.length; i++) {
            bytes32 poolId = borrows[i].poolId;
            uint256 debt = borrows[i].debt;
            uint256 collateral = borrows[i].collateral;
            // get the pool info
            Pool memory pool = pools[poolId];
            // make sure the pool exists
            if (pool.lender == address(0)) revert PoolConfig();
            // validate the loan
            if (debt < pool.minLoanSize) revert LoanTooSmall();
            if (debt > pool.poolBalance) revert LoanTooLarge();
            if (collateral == 0) revert ZeroCollateral();
            // make sure the user isn't borrowing too much
            uint256 loanRatio = (debt * 10 ** 18) / collateral;
            if (loanRatio > pool.maxLoanRatio) revert RatioTooHigh();
            // create the loan
            Loan memory loan = Loan({
                lender: pool.lender,
                borrower: msg.sender,
                loanToken: pool.loanToken,
                collateralToken: pool.collateralToken,
                debt: debt,
                collateral: collateral,
                interestRate: pool.interestRate,
                startTimestamp: block.timestamp,
                auctionStartTimestamp: type(uint256).max,
                auctionLength: pool.auctionLength
            });
            // update the pool balance
            _updatePoolBalance(poolId, pools[poolId].poolBalance - debt);
            pools[poolId].outstandingLoans += debt;
            // calculate the fees
            uint256 fees = (debt * borrowerFee) / 10000;
            // transfer fees
            IERC20(loan.loanToken).transfer(feeReceiver, fees);
            // transfer the loan tokens from the pool to the borrower
            IERC20(loan.loanToken).transfer(msg.sender, debt - fees);
            // transfer the collateral tokens from the borrower to the contract
            IERC20(loan.collateralToken).transferFrom(
                msg.sender,
                address(this),
                collateral
            );
            loans.push(loan);
            emit Borrowed(
                msg.sender,
                pool.lender,
                loans.length - 1,
                debt,
                collateral,
                pool.interestRate,
                block.timestamp
            );
        }
    }

    /// @notice repay a loan
    /// can be called by anyone
    /// @param loanIds the ids of the loans to repay
    function repay(uint256[] calldata loanIds) public {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // calculate the interest
            (
                uint256 lenderInterest,
                uint256 protocolInterest
            ) = _calculateInterest(loan);

            bytes32 poolId = getPoolId(
                loan.lender,
                loan.loanToken,
                loan.collateralToken
            );

            // update the pool balance
            _updatePoolBalance(
                poolId,
                pools[poolId].poolBalance + loan.debt + lenderInterest
            );
            pools[poolId].outstandingLoans -= loan.debt;

            // transfer the loan tokens from the borrower to the pool
            IERC20(loan.loanToken).transferFrom(
                msg.sender,
                address(this),
                loan.debt + lenderInterest
            );
            // transfer the protocol fee to the fee receiver
            IERC20(loan.loanToken).transferFrom(
                msg.sender,
                feeReceiver,
                protocolInterest
            );
            // transfer the collateral tokens from the contract to the borrower
            IERC20(loan.collateralToken).transfer(
                loan.borrower,
                loan.collateral
            );
            emit Repaid(
                msg.sender,
                loan.lender,
                loanId,
                loan.debt,
                loan.collateral,
                loan.interestRate,
                loan.startTimestamp
            );
            // delete the loan
            delete loans[loanId];
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         REFINANCE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice give your loans to another pool
    /// can only be called by the lender
    /// @param loanIds the ids of the loans to give
    /// @param poolIds the id of the pools to give to
    function giveLoan(
        uint256[] calldata loanIds,
        bytes32[] calldata poolIds
    ) external {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            bytes32 poolId = poolIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (msg.sender != loan.lender) revert Unauthorized();
            // get the pool info
            Pool memory pool = pools[poolId];
            // validate the new loan
            if (pool.loanToken != loan.loanToken) revert TokenMismatch();
            if (pool.collateralToken != loan.collateralToken)
                revert TokenMismatch();
            // new interest rate cannot be higher than old interest rate
            if (pool.interestRate > loan.interestRate) revert RateTooHigh();
            // auction length cannot be shorter than old auction length
            if (pool.auctionLength < loan.auctionLength) revert AuctionTooShort();
            // calculate the interest
            (
                uint256 lenderInterest,
                uint256 protocolInterest
            ) = _calculateInterest(loan);
            uint256 totalDebt = loan.debt + lenderInterest + protocolInterest;
            if (pool.poolBalance < totalDebt) revert PoolTooSmall();
            if (totalDebt < pool.minLoanSize) revert LoanTooSmall();
            uint256 loanRatio = (totalDebt * 10 ** 18) / loan.collateral;
            if (loanRatio > pool.maxLoanRatio) revert RatioTooHigh();
            // update the pool balance of the new lender
            _updatePoolBalance(poolId, pool.poolBalance - totalDebt);
            pools[poolId].outstandingLoans += totalDebt;

            // update the pool balance of the old lender
            bytes32 oldPoolId = getPoolId(
                loan.lender,
                loan.loanToken,
                loan.collateralToken
            );
            _updatePoolBalance(
                oldPoolId,
                pools[oldPoolId].poolBalance + loan.debt + lenderInterest
            );
            pools[oldPoolId].outstandingLoans -= loan.debt;

            // transfer the protocol fee to the governance
            IERC20(loan.loanToken).transfer(feeReceiver, protocolInterest);

            emit Repaid(
                loan.borrower,
                loan.lender,
                loanId,
                loan.debt + lenderInterest + protocolInterest,
                loan.collateral,
                loan.interestRate,
                loan.startTimestamp
            );

            // update the loan with the new info
            loans[loanId].lender = pool.lender;
            loans[loanId].interestRate = pool.interestRate;
            loans[loanId].startTimestamp = block.timestamp;
            loans[loanId].auctionStartTimestamp = type(uint256).max;
            loans[loanId].debt = totalDebt;

            emit Borrowed(
                loan.borrower,
                pool.lender,
                loanId,
                loans[loanId].debt,
                loans[loanId].collateral,
                pool.interestRate,
                block.timestamp
            );
        }
    }

    /// @notice start a refinance auction
    /// can only be called by the lender
    /// @param loanIds the ids of the loans to refinance
    function startAuction(uint256[] calldata loanIds) public {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (msg.sender != loan.lender) revert Unauthorized();
            if (loan.auctionStartTimestamp != type(uint256).max)
                revert AuctionStarted();

            // set the auction start timestamp
            loans[loanId].auctionStartTimestamp = block.timestamp;
            emit AuctionStart(
                loan.borrower,
                loan.lender,
                loanId,
                loan.debt,
                loan.collateral,
                block.timestamp,
                loan.auctionLength
            );
        }
    }

    /// @notice buy a loan in a refinance auction
    /// can be called by anyone but you must have a pool with tokens
    /// @param loanId the id of the loan to refinance
    /// @param poolId the pool to accept
    function buyLoan(uint256 loanId, bytes32 poolId) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // validate the loan
        if (loan.auctionStartTimestamp == type(uint256).max)
            revert AuctionNotStarted();
        if (block.timestamp > loan.auctionStartTimestamp + loan.auctionLength)
            revert AuctionEnded();
        // calculate the current interest rate
        uint256 timeElapsed = block.timestamp - loan.auctionStartTimestamp;
        uint256 currentAuctionRate = (MAX_INTEREST_RATE * timeElapsed) /
            loan.auctionLength;
        // validate the rate
        if (pools[poolId].interestRate > currentAuctionRate) revert RateTooHigh();
        // calculate the interest
        (uint256 lenderInterest, uint256 protocolInterest) = _calculateInterest(
            loan
        );

        // reject if the pool is not big enough
        uint256 totalDebt = loan.debt + lenderInterest + protocolInterest;
        if (pools[poolId].poolBalance < totalDebt) revert PoolTooSmall();

        // if they do have a big enough pool then transfer from their pool
        _updatePoolBalance(poolId, pools[poolId].poolBalance - totalDebt);
        pools[poolId].outstandingLoans += totalDebt;

        // now update the pool balance of the old lender
        bytes32 oldPoolId = getPoolId(
            loan.lender,
            loan.loanToken,
            loan.collateralToken
        );
        _updatePoolBalance(
            oldPoolId,
            pools[oldPoolId].poolBalance + loan.debt + lenderInterest
        );
        pools[oldPoolId].outstandingLoans -= loan.debt;

        // transfer the protocol fee to the governance
        IERC20(loan.loanToken).transfer(feeReceiver, protocolInterest);

        emit Repaid(
            loan.borrower,
            loan.lender,
            loanId,
            loan.debt + lenderInterest + protocolInterest,
            loan.collateral,
            loan.interestRate,
            loan.startTimestamp
        );

        // update the loan with the new info
        loans[loanId].lender = msg.sender;
        loans[loanId].interestRate = pools[poolId].interestRate;
        loans[loanId].startTimestamp = block.timestamp;
        loans[loanId].auctionStartTimestamp = type(uint256).max;
        loans[loanId].debt = totalDebt;

        emit Borrowed(
            loan.borrower,
            msg.sender,
            loanId,
            loans[loanId].debt,
            loans[loanId].collateral,
            pools[poolId].interestRate,
            block.timestamp
        );
        emit LoanBought(loanId);
    }

    /// @notice make a pool and buy the loan in one transaction
    /// can be called by anyone
    /// @param p the pool info
    /// @param loanId the id of the loan to refinance
    function zapBuyLoan(Pool calldata p, uint256 loanId) external {
        bytes32 poolId = setPool(p);
        buyLoan(loanId, poolId);
    }

    /// @notice sieze a loan after a failed refinance auction
    /// can be called by anyone
    /// @param loanIds the ids of the loans to sieze
    function seizeLoan(uint256[] calldata loanIds) public {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (loan.auctionStartTimestamp == type(uint256).max)
                revert AuctionNotStarted();
            if (
                block.timestamp <
                loan.auctionStartTimestamp + loan.auctionLength
            ) revert AuctionNotEnded();
            // calculate the fee
            uint256 govFee = (borrowerFee * loan.collateral) / 10000;
            // transfer the protocol fee to governance
            IERC20(loan.collateralToken).transfer(feeReceiver, govFee);
            // transfer the collateral tokens from the contract to the lender
            IERC20(loan.collateralToken).transfer(
                loan.lender,
                loan.collateral - govFee
            );

            bytes32 poolId = keccak256(
                abi.encode(loan.lender, loan.loanToken, loan.collateralToken)
            );

            // update the pool outstanding loans
            pools[poolId].outstandingLoans -= loan.debt;

            emit LoanSiezed(
                loan.borrower,
                loan.lender,
                loanId,
                loan.collateral
            );
            // delete the loan
            delete loans[loanId];
        }
    }

    /// @notice refinance a loan to a new offer
    /// can only be called by the borrower
    /// @param refinances a struct of all desired debt positions to be refinanced
    function refinance(Refinance[] calldata refinances) public {
        for (uint256 i = 0; i < refinances.length; i++) {
            uint256 loanId = refinances[i].loanId;
            bytes32 poolId = refinances[i].poolId;
            bytes32 oldPoolId = keccak256(
                abi.encode(
                    loans[loanId].lender,
                    loans[loanId].loanToken,
                    loans[loanId].collateralToken
                )
            );
            uint256 debt = refinances[i].debt;
            uint256 collateral = refinances[i].collateral;

            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (msg.sender != loan.borrower) revert Unauthorized();

            // get the pool info
            Pool memory pool = pools[poolId];
            // validate the new loan
            if (pool.loanToken != loan.loanToken) revert TokenMismatch();
            if (pool.collateralToken != loan.collateralToken)
                revert TokenMismatch();
            if (pool.poolBalance < debt) revert LoanTooLarge();
            if (debt < pool.minLoanSize) revert LoanTooSmall();
            uint256 loanRatio = (debt * 10 ** 18) / collateral;
            if (loanRatio > pool.maxLoanRatio) revert RatioTooHigh();

            // calculate the interest
            (
                uint256 lenderInterest,
                uint256 protocolInterest
            ) = _calculateInterest(loan);
            uint256 debtToPay = loan.debt + lenderInterest + protocolInterest;

            // update the old lenders pool
            _updatePoolBalance(
                oldPoolId,
                pools[oldPoolId].poolBalance + loan.debt + lenderInterest
            );
            pools[oldPoolId].outstandingLoans -= loan.debt;

            // now lets deduct our tokens from the new pool
            _updatePoolBalance(poolId, pools[poolId].poolBalance - debt);
            pools[poolId].outstandingLoans += debt;

            if (debtToPay > debt) {
                // we owe more in debt so we need the borrower to give us more loan tokens
                // transfer the loan tokens from the borrower to the contract
                IERC20(loan.loanToken).transferFrom(
                    msg.sender,
                    address(this),
                    debtToPay - debt
                );
            } else if (debtToPay < debt) {
                // we have excess loan tokens so we give some back to the borrower
                // first we take our borrower fee
                uint256 fee = (borrowerFee * (debt - debtToPay)) / 10000;
                IERC20(loan.loanToken).transfer(feeReceiver, fee);
                // transfer the loan tokens from the contract to the borrower
                IERC20(loan.loanToken).transfer(msg.sender, debt - debtToPay - fee);
            }
            // transfer the protocol fee to governance
            IERC20(loan.loanToken).transfer(feeReceiver, protocolInterest);

            // update loan debt
            loans[loanId].debt = debt;
            // update loan collateral
            if (collateral > loan.collateral) {
                // transfer the collateral tokens from the borrower to the contract
                IERC20(loan.collateralToken).transferFrom(
                    msg.sender,
                    address(this),
                    collateral - loan.collateral
                );
            } else if (collateral < loan.collateral) {
                // transfer the collateral tokens from the contract to the borrower
                IERC20(loan.collateralToken).transfer(
                    msg.sender,
                    loan.collateral - collateral
                );
            }

            emit Repaid(
                msg.sender,
                loan.lender,
                loanId,
                debt,
                collateral,
                loan.interestRate,
                loan.startTimestamp
            );

            loans[loanId].collateral = collateral;
            // update loan interest rate
            loans[loanId].interestRate = pool.interestRate;
            // update loan start timestamp
            loans[loanId].startTimestamp = block.timestamp;
            // update loan auction start timestamp
            loans[loanId].auctionStartTimestamp = type(uint256).max;
            // update loan auction length
            loans[loanId].auctionLength = pool.auctionLength;
            // update loan lender
            loans[loanId].lender = pool.lender;
            // update pool balance
            pools[poolId].poolBalance -= debt;
            emit Borrowed(
                msg.sender,
                pool.lender,
                loanId,
                debt,
                collateral,
                pool.interestRate,
                block.timestamp
            );
            emit Refinanced(loanId);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         INTERNAL                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice calculates interest accrued on a loan
    /// @param l the loan to calculate for
    /// @return interest the interest accrued
    /// @return fees the fees accrued
    function _calculateInterest(
        Loan memory l
    ) internal view returns (uint256 interest, uint256 fees) {
        uint256 timeElapsed = block.timestamp - l.startTimestamp;
        interest = (l.interestRate * l.debt * timeElapsed) / 10000 / 365 days;
        fees = (lenderFee * interest) / 10000;
        interest -= fees;
    }

    /// @notice update the balance of a pool and emit the event
    /// @param poolId the id of the pool to update
    /// @param newBalance the new balance of the pool
    function _updatePoolBalance(bytes32 poolId, uint256 newBalance) internal {
        pools[poolId].poolBalance = newBalance;
        emit PoolBalanceUpdated(poolId, newBalance);
    }
}
