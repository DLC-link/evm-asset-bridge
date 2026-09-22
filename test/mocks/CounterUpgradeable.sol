// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// A small upgradeable contract with no relation to the bridge. The upgrade
/// scripts must drive it, which proves they hold no bridge knowledge.
contract CounterV1 is Initializable {
    uint256 public count;

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 start) external initializer {
        count = start;
    }

    function increment() external virtual {
        count += 1;
    }
}

/// The next version. `step` takes the slot after `count`, and `setStep` is
/// the reinitializer that an `upgradeAndCall` payload runs.
contract CounterV2 is CounterV1 {
    uint256 public step;

    error StepIsZero();

    function setStep(uint256 step_) external reinitializer(2) {
        if (step_ == 0) {
            revert StepIsZero();
        }
        step = step_;
    }

    function increment() external override {
        count += step;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// An implementation whose constructor takes an argument. The deploy script
/// must refuse it.
contract CounterWithConstructorArg {
    uint256 public immutable start;

    constructor(uint256 start_) {
        start = start_;
    }
}
