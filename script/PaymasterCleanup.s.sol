// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import { VerifyingPaymaster } from "../src/VerifyingPaymaster.sol";

/// @title PaymasterCleanup
/// @notice Withdraw remaining stake + deposit dust from a VerifyingPaymaster.
///         Run AFTER E2EPaymaster (which calls unlockStake) and unstakeDelay has elapsed.
/// @dev    Usage: PAYMASTER=0x... forge script script/PaymasterCleanup.s.sol --rpc-url $RPC_URL --broadcast
contract PaymasterCleanup is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address pmAddr = vm.envAddress("PAYMASTER");
        VerifyingPaymaster paymaster = VerifyingPaymaster(payable(pmAddr));

        console.log("PaymasterCleanup");
        console.log("  Paymaster:", pmAddr);
        console.log("  Owner:    ", deployer);

        uint256 deposit = paymaster.getDeposit();
        console.log("  Deposit:  ", deposit, "wei");

        vm.startBroadcast(deployerPk);

        // Withdraw remaining deposit dust
        if (deposit > 0) {
            paymaster.withdrawTo(payable(deployer), deposit);
            console.log("  Withdrew deposit:", deposit, "wei");
        }

        // Withdraw stake (must be called after unstakeDelay since unlockStake)
        paymaster.withdrawStake(payable(deployer));
        console.log("  Withdrew stake");

        vm.stopBroadcast();

        console.log("  DONE: all paymaster funds recovered");
    }
}
