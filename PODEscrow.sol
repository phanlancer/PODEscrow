pragma solidity ^0.4.24;

/*
 * ERC20 interface
 * see https://github.com/ethereum/EIPs/issues/20
 */
contract ERC20 {
  uint public totalSupply;
  function balanceOf(address who) public view returns (uint);
  function allowance(address owner, address spender) public view returns (uint);

  function transfer(address to, uint value) public returns (bool ok);
  function transferFrom(address from, address to, uint value) public returns (bool ok);
  function approve(address spender, uint value) public returns (bool ok);
  event Transfer(address indexed from, address indexed to, uint value);
  event Approval(address indexed owner, address indexed spender, uint value);
}

/**
 * Math operations with safety checks
 */
contract SafeMath {
  function safeMul(uint a, uint b) internal pure returns (uint) {
    uint c = a * b;
    assert(a == 0 || c / a == b);
    return c;
  }

  function safeDiv(uint a, uint b) internal pure returns (uint) {
    assert(b > 0);
    uint c = a / b;
    assert(a == b * c + a % b);
    return c;
  }

  function safeSub(uint a, uint b) internal pure returns (uint) {
    assert(b <= a);
    return a - b;
  }

  function safeAdd(uint a, uint b) internal pure returns (uint) {
    uint c = a + b;
    assert(c>=a && c>=b);
    return c;
  }

  function max64(uint64 a, uint64 b) internal pure returns (uint64) {
    return a >= b ? a : b;
  }

  function min64(uint64 a, uint64 b) internal pure returns (uint64) {
    return a < b ? a : b;
  }

  function max256(uint256 a, uint256 b) internal pure returns (uint256) {
    return a >= b ? a : b;
  }

  function min256(uint256 a, uint256 b) internal pure returns (uint256) {
    return a < b ? a : b;
  }
}

/**
 * Contract function to receive approval and execute function in one call
 *
 * Borrowed from MiniMeToken
 */
contract ApproveAndCallFallBack {
  function receiveApproval(address from, uint256 tokens, address token, bytes data) public;
}

/**
 * Standard ERC20 token with approve() condition.
 */
contract StandardToken is ERC20, SafeMath {

  mapping(address => uint) balances;
  mapping (address => mapping (address => uint)) allowed;

  // Interface marker
  bool public constant isToken = true;

  /**
  *
  * Fix for the ERC20 short address attack
  *
  * http://vessenes.com/the-erc20-short-address-attack-explained/
  */
  modifier onlyPayloadSize(uint size) {
    if(msg.data.length < size + 4) {
      revert("not enough payload size");
    }
    _;
  }

  function transfer(address _to, uint _value) public onlyPayloadSize(2 * 32) returns (bool success) {
    balances[msg.sender] = safeSub(balances[msg.sender], _value);
    balances[_to] = safeAdd(balances[_to], _value);
    emit Transfer(msg.sender, _to, _value);
    return true;
  }

  function transferFrom(address _from, address _to, uint _value) public returns (bool success) {
    uint _allowance = allowed[_from][msg.sender];

    balances[_to] = safeAdd(balances[_to], _value);
    balances[_from] = safeSub(balances[_from], _value);
    allowed[_from][msg.sender] = safeSub(_allowance, _value);
    emit Transfer(_from, _to, _value);
    return true;
  }

  function balanceOf(address _owner) public view returns (uint balance) {
    return balances[_owner];
  }

  function approve(address _spender, uint _value) public returns (bool success) {

    // To change the approve amount you first have to reduce the addresses`
    //  allowance to zero by calling `approve(_spender, 0)` if it is not
    //  already 0 to mitigate the race condition described here:
    //  https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    if ((_value != 0) && (allowed[msg.sender][_spender] != 0)) revert("spender's allowance is not zero");

    allowed[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }

  function allowance(address _owner, address _spender) public view returns (uint remaining) {
    return allowed[_owner][_spender];
  }

}



/**
 * A trait that allows any token owner to decrease the token supply.
 *
 * Add a Burned event to differentiate from normal transfers.
 * ERC-20 has not standardized on the burn event yet.
 *
 */
contract BurnableToken is StandardToken {

  address public constant BURN_ADDRESS = 0;

  /** How many tokens we burned */
  event Burned(address burner, uint burnedAmount);

  /**
  * Burn extra tokens from a balance.
  */
  function burn(uint burnAmount) public {
    address burner = msg.sender;
    balances[burner] = safeSub(balances[burner], burnAmount);
    totalSupply = safeSub(totalSupply, burnAmount);
    emit Burned(burner, burnAmount);

    // Keep token balance tracking services happy by sending the burned amount to
    // "burn address", so that it will show up as a ERC-20 transaction
    // in ubiq explorer, etc. as there is no standarized burn event yet
    emit Transfer(burner, BURN_ADDRESS, burnAmount);
  }

}


/**
 * Upgrade agent interface
 *
 * Upgrade agent transfers tokens to a new contract.
 * Upgrade agent itself can be the token contract, or just a middle man contract doing the heavy lifting.
 */
contract UpgradeAgent {

  uint public originalSupply;

  /** Interface marker */
  function isUpgradeAgent() public pure returns (bool) {
    return true;
  }

  function upgradeFrom(address _from, uint256 _value) public;

}


/**
 * A token upgrade mechanism where users can opt-in amount of tokens to the next smart contract revision.
 */
contract UpgradeableToken is StandardToken {

  /** Contract / person who can set the upgrade path. This can be the same as team multisig wallet, as what it is with its default value. */
  address public upgradeMaster;

  /** The next contract where the tokens will be migrated. */
  UpgradeAgent public upgradeAgent;

  /** How many tokens we have upgraded by now. */
  uint256 public totalUpgraded;

  /**
  * Upgrade states.
  *
  * - NotAllowed: The child contract has not reached a condition where the upgrade can bgun
  * - WaitingForAgent: Token allows upgrade, but we don't have a new agent yet
  * - ReadyToUpgrade: The agent is set, but not a single token has been upgraded yet
  * - Upgrading: Upgrade agent is set and the balance holders can upgrade their tokens
  *
  */
  enum UpgradeState {Unknown, NotAllowed, WaitingForAgent, ReadyToUpgrade, Upgrading}

  /**
  * Somebody has upgraded some of his tokens.
  */
  event Upgrade(address indexed _from, address indexed _to, uint256 _value);

  /**
  * New upgrade agent available.
  */
  event UpgradeAgentSet(address agent);

  /**
  * Do not allow construction without upgrade master set.
  */
  constructor(address _upgradeMaster) public {
    upgradeMaster = _upgradeMaster;
  }

  /**
  * Allow the token holder to upgrade some of their tokens to a new contract.
  */
  function upgrade(uint256 value) public {

    UpgradeState state = getUpgradeState();
    if(!(state == UpgradeState.ReadyToUpgrade || state == UpgradeState.Upgrading)) {
      // Called in a bad state
      revert("state is not ready to upgrade or currently under upgrading");
    }

    // Validate input value.
    if (value == 0) revert("zero token to upgrade");

    balances[msg.sender] = safeSub(balances[msg.sender], value);

    // Take tokens out from circulation
    totalSupply = safeSub(totalSupply, value);
    totalUpgraded = safeAdd(totalUpgraded, value);

    // Upgrade agent reissues the tokens
    upgradeAgent.upgradeFrom(msg.sender, value);
    emit Upgrade(msg.sender, upgradeAgent, value);
  }

  /**
  * Set an upgrade agent that handles
  */
  function setUpgradeAgent(address agent) external {

    if(!canUpgrade()) {
      // The token is not yet in a state that we could think upgrading
      revert("the token is not yest in a state to upgrade");
    }

    if (agent == 0x0) revert("invalid agent address");
    // Only a master can designate the next agent
    if (msg.sender != upgradeMaster) revert("only a master can designate the next agent");
    // Upgrade has already begun for an agent
    if (getUpgradeState() == UpgradeState.Upgrading) revert("upgrade has already begun for an agent");

    upgradeAgent = UpgradeAgent(agent);

    // Bad interface
    if(!upgradeAgent.isUpgradeAgent()) revert("bad interface");
    // Make sure that token supplies match in source and target
    if (upgradeAgent.originalSupply() != totalSupply) revert("make sure that token supplies match in source and target");

    emit UpgradeAgentSet(upgradeAgent);
  }

  /**
  * Get the state of the token upgrade.
  */
  function getUpgradeState() public view returns(UpgradeState) {
    if(!canUpgrade()) return UpgradeState.NotAllowed;
    else if(address(upgradeAgent) == 0x00) return UpgradeState.WaitingForAgent;
    else if(totalUpgraded == 0) return UpgradeState.ReadyToUpgrade;
    else return UpgradeState.Upgrading;
  }

  /**
  * Change the upgrade master.
  *
  * This allows us to set a new owner for the upgrade mechanism.
  */
  function setUpgradeMaster(address master) public {
    if (master == 0x0) revert("address is invalid");
    if (msg.sender != upgradeMaster) revert("only a master can upgrade master");
    upgradeMaster = master;
  }

  /**
  * Child contract can enable to provide the condition when the upgrade can begun.
  */
  function canUpgrade() public pure returns(bool) {
    return true;
  }
}




/**
 * Centrally issued UBIQ token.
 *
 * We mix in burnable and upgradeable traits.
 *
 * Token supply is created in the token contract creation and allocated to owner.
 * The owner can then transfer from its supply to crowdsale participants.
 * The owner, or anybody, can burn any excessive tokens they are holding.
 *
 */
contract PressOnDemandToken is BurnableToken, UpgradeableToken {

  string public name;                   // Token Name
  uint8 public decimals;                // How many decimals to show.
  string public symbol;                 // An identifier: eg SBX, XPR etc..
  string public version = "H1.1";
  uint256 public unitsOneUBIQCanBuy;     // How many units of your coin can be bought by 1 UBIQ?
  uint256 public totalUBIQInWei;         // WEI is the smallest unit of UBIQ. We'll store the total UBIQ raised via our ICO here.
  address public fundsWallet;           // Where should the raised UBIQ go?

  event Pause();
  event Unpause();

  bool public paused = false;

  constructor() public UpgradeableToken(msg.sender) {
    name = "PressOnDemand Token";
    symbol = "POD";
    totalSupply = 100000000000000000000000000;
    decimals = 18; //totalSupply will be divided by decimal amount
    unitsOneUBIQCanBuy = 2;  // You can buy 2 PODs with 1 UBQ
    fundsWallet = msg.sender; //SET WALLET FOR FUNDING

    // Allocate initial balance to the owner
    balances[msg.sender] = 100000000000000000000000000; //TOKEN OWNER
  }

  modifier onlyOwner() {
    require(msg.sender == fundsWallet, "sender is not the contract owner");
    _;
  }

  modifier whenNotPaused() {
    require(!paused, "contract is paused");
    _;
  }

  modifier whenPaused() {
    require(paused, "contract is not paused");
    _;
  }

  function pause() public onlyOwner whenNotPaused {
    paused = true;
    emit Pause();
  }

  function unpause() public onlyOwner whenPaused {
    paused = false;
    emit Unpause();
  }

  function setUnitsOneUBIQCanBuy(uint256 newValue) external onlyOwner {
    unitsOneUBIQCanBuy = newValue;
  }


  //for ICO
  function() external whenNotPaused payable {
    totalUBIQInWei = safeAdd(totalUBIQInWei, msg.value);
    uint amount = safeMul(msg.value, unitsOneUBIQCanBuy);
    require(balances[fundsWallet] >= amount, "contract balance is not sufficient for ICO");

    balances[fundsWallet] = safeSub(balances[fundsWallet], amount);
    balances[msg.sender] = safeAdd(balances[msg.sender], amount);

    emit Transfer(fundsWallet, msg.sender, amount); // Broadcast a message to the blockchain

    //Transfer UBIQ to fundsWallet
    fundsWallet.transfer(msg.value);
  }

  /* Approves and then calls the receiving contract */
  function approveAndCall(address _spender, uint256 _value, bytes _extraData) public returns (bool success) {
    allowed[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    ApproveAndCallFallBack(_spender).receiveApproval(msg.sender, _value, this, _extraData);
    return true;
  }

}

/**
 * @notice PressOnDemand Escrow Contract. It uses PressOnDemandToken(ERC20)
 *
 */
contract PODEscrow {
  /* there are three payment status - pending, completed, refunded */
  enum PaymentStatus { Pending, Completed, Refunded }

  /* event for payment creation. create a payment struct */
  event PaymentCreation(uint indexed orderId, address indexed seller, address indexed buyer, uint value);
  /* event for payment completion even it's released or refunded */
  event PaymentCompletion(uint indexed orderId, address indexed seller, address indexed buyer, uint value, PaymentStatus status);

  /**
   * @notice payment struct 
   */
  struct Payment {
    address seller;
    address buyer;
    uint value;
    PaymentStatus status;
    bool refundApproved;
  }

  /* mapping orderId to payment */
  mapping(uint => Payment) payments;
  /* address to PressOnDemandToken*/
  PressOnDemandToken currency;
  /* address where the fee goes */
  address collectionAddress;

  constructor(PressOnDemandToken _currency) public {
    currency = _currency;
    collectionAddress = msg.sender;
  }

  /**
   * @notice transfer tokens from seller to this contract as an escrow. create a payment struct
   */
  function createPayment(uint _orderId, address _seller, address _buyer, uint _value) external {
    require(currency.transferFrom(_buyer, address(this), _value), "failed to send token to contract");
    // value is the Token amount
    payments[_orderId] = Payment(_seller, _buyer, _value, PaymentStatus.Pending, false);
    emit PaymentCreation(_orderId, _seller, _buyer, _value);
  }

  /**
   * @notice release funds to seller
   */
  function release(uint _orderId) external {
    completePayment(_orderId, PaymentStatus.Completed);
  }

  /**
   * @notice refund funds to buyer
   */
  function refund(uint _orderId) external {
    completePayment(_orderId, PaymentStatus.Refunded);
  }

  /**
   * @notice approve the refund
   */
  function approveRefund(uint _orderId) external {
    Payment storage payment = payments[_orderId];
    require(msg.sender == payment.seller, "msg sender should be seller");
    payment.refundApproved = true;
  }

  /**
   * @notice complete payment either release or refund.
   */
  function completePayment(uint _orderId, PaymentStatus _status) private {
    Payment storage payment = payments[_orderId];
    require(payment.buyer == msg.sender, "only buyer can complete the payment");
    require(payment.status == PaymentStatus.Pending, "invalid payment status");
    if (_status == PaymentStatus.Refunded) {
      require(payment.refundApproved, "refund should be approved first");

      currency.transfer(payment.buyer, payment.value);
    } else {
      currency.transfer(payment.seller, payment.value);
    }

    payment.status = _status;
    emit PaymentCompletion(_orderId, payment.seller, payment.buyer, payment.value, _status);
  }
}
