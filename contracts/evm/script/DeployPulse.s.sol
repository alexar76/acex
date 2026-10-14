// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;
import {Script, console2} from "forge-std/Script.sol";
import {PulseDistributor} from "../src/PulseDistributor.sol";
contract DeployPulse is Script {
  function run() external {
    uint256 k = vm.envUint("PRIVATE_KEY");
    address o = vm.envAddress("OWNER");
    vm.startBroadcast(k);
    PulseDistributor d = new PulseDistributor(o);
    console2.log("PulseDistributor", address(d));
    vm.stopBroadcast();
  }
}
