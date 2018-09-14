pragma solidity ^0.4.24;

import "https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/ownership/Ownable.sol";

contract Escrow is Ownable {
  enum PaymentStatus { Pending, Completed, Refunded }

  event PaymentCreation(uint indexed orderId, address indexed customer, uint value);
  event PaymentCompletion(uint indexed orderId, address indexed customer, uint value, PaymentStatus status);

  struct Payment {
    address buyer;
    address seller;
    uint value;
    PaymentStatus status;
    bool refundApproved;
  }

  mapping(uint => Payment) public payments;
  ERC20 public currency;
  address public collectionAddress;

  function Escrow(ERC20 _currency, address _collectionAddress) public {
    currency = _currency;
    collectionAddress = _collectionAddress;
  }

  function createPayment(uint _orderId, address _seller, uint _value) external {
    payments[_orderId] = Payment(msg.sender, _seller, _value, PaymentStatus.Pending, false);
    emit PaymentCreation(_orderId, _customer, _value);
  }

  function release(uint _orderId) external {
    completePayment(_orderId, collectionAddress, PaymentStatus.Completed);
  }

  function refund(uint _orderId) external {
    completePayment(_orderId, msg.sender, PaymentStatus.Refunded);
  }

  function approveRefund(uint _orderId) external {
    require(msg.sender == collectionAddress);
    Payment storage payment = payments[_orderId];
    payment.refundApproved = true;
  }

  function completePayment(uint _orderId, address _receiver, PaymentStatus _status) private {
    Payment storage payment = payments[_orderId];
    require(payment.customer == msg.sender);
    require(payment.status == PaymentStatus.Pending);
    if (_status == PaymentStatus.Refunded) {
      require(payment.refundApproved);
    }
    currency.transfer(_receiver, payment.value);
    payment.status = _status;
    emit PaymentCompletion(_orderId, payment.customer, payment.value, _status);
  }
}
