// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Minimal Phase 0 probe: the smallest possible contract that can hold an ERC-20.
/// Deployed only to answer one question — can a CONTRACT (not just an EOA) receive
/// a Robinhood Stock Token? Source reading says yes and the deny-list is default-open,
/// but a live transfer is the only thing that actually proves it.
contract AssayReceiver {
    address public immutable owner;
    constructor() { owner = msg.sender; }

    /// Escape hatch, so the probe never traps the token it was sent.
    function sweep(address token, address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
    }
}
