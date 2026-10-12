// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract SpotBalanceMock {
    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    mapping(address => mapping(uint64 => SpotBalance)) public spotBalances;

    constructor() {}

    function setSpotHypeBalance(address user, uint256 total) external {
        total = total / 1e10;

        spotBalances[user][150] = SpotBalance({
            total: uint64(total),
            hold: 0,
            entryNtl: 0
        });
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (address user, uint64 token) = abi.decode(data, (address, uint64));
        
        SpotBalance memory balance = spotBalances[user][token];
        
        return abi.encode(balance);
    }
}
