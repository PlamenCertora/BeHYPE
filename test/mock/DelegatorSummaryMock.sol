// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract DelegatorSummaryMock {
    struct DelegatorSummary {
        uint64 delegated;
        uint64 undelegated;
        uint64 totalPendingWithdrawal;
        uint64 nPendingWithdrawals;
    }

    mapping(address => DelegatorSummary) public delegatorSummaries;

    constructor() {}

    function setDelegatorSummary(
        address user, 
        uint256 delegated, 
        uint256 undelegated, 
        uint256 totalPendingWithdrawal
    ) external {
        delegated = delegated / 1e10;
        undelegated = undelegated / 1e10;

        delegatorSummaries[user] = DelegatorSummary({
            delegated: uint64(delegated),
            undelegated: uint64(undelegated),
            totalPendingWithdrawal: uint64(totalPendingWithdrawal),
            nPendingWithdrawals: 0
        });
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        address user = abi.decode(data, (address));
        
        DelegatorSummary memory summary = delegatorSummaries[user];
        
        return abi.encode(summary);
    }
}
