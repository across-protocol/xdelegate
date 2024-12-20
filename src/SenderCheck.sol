pragma solidity ^0.8.0;

contract SenderCheck {
    event Check(address sender);

    function check() external {
        emit Check(msg.sender);
    }
}
