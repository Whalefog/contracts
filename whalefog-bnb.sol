// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "./MerkleTreeWithHistory.sol";

interface IDepositVerifier {
  function verifyProof(bytes memory _proof, uint256[2] memory _input) external  returns(bool);
}

interface IWithdrawVerifier {
  function verifyProof(bytes memory _proof, uint256[8] memory _input) external  returns(bool);
}


contract ReentrancyGuard {
    uint256 private _guardCounter = 1;

    modifier nonReentrant() {
        _guardCounter += 1;
        uint256 localCounter = _guardCounter;
        _;
        require(localCounter == _guardCounter);
    }
}

contract whalefogBNB is MerkleTreeWithHistory, ReentrancyGuard {
  mapping(bytes32 => bool) public vouchers;
  mapping(bytes32 => bool) public commitments;
  IDepositVerifier public dpVerifier;
  IWithdrawVerifier public wdVerifier;
  address public operator;

  uint256 public bnbfee = 0;       //unit is gwei
  uint256 public relayfee = 0;   //100 percent is 100,000
  uint256 public min = 0;

  modifier onlyOperator {
    require(msg.sender == operator, "Only operator can call this function.");
    _;
  }

  event Deposit(bytes32 indexed commitment, uint256 balance, uint32 leafIndex, uint256 timestamp);
  event Withdrawal(address to, bytes32 voucher, uint256 balance, address indexed relayer, uint256 fee, uint32 leafIndex, uint256 timestamp);

  constructor(
    IDepositVerifier _dpVerifier,
    IWithdrawVerifier _wdVerifier,
    IHasher _hasher,
    uint32 _merkleTreeHeight
  ) MerkleTreeWithHistory(_merkleTreeHeight, _hasher)  {
    dpVerifier = _dpVerifier;
    wdVerifier = _wdVerifier;
    operator = msg.sender;
  }

  
  function deposit(bytes32 _commitment, uint248 _balance, bytes calldata _proof) external payable nonReentrant {
    require(!commitments[_commitment], "The commitment has been submitted");
    require(_balance >= min ,"deposit balance is less than minimum");
    require(msg.value  >= (bnbfee + _balance),"msg value is less than bnb fee ");
    require(dpVerifier.verifyProof(_proof, [uint256(_balance),uint256(_commitment)]), "Invalid deposit proof");
    
    uint32 insertedIndex = _insert(_commitment);
    commitments[_commitment] = true;
    

    emit Deposit(_commitment, uint256(_balance), insertedIndex, block.timestamp);
  }

  
  function withdraw(bytes calldata _proof, bytes32 _root, bytes32 _voucher,  uint248 _amount,bytes32 _commitment, address payable _recipient, address payable _relayer, uint256 _fee, uint256 _refund) external payable nonReentrant {
    require(_fee <= (_amount * relayfee / 100000), "Fee exceeds transfer value");
    require(_amount >= min ,"withdraw balance is less than minimum");
    require(!vouchers[_voucher], "The voucher has been already used");
    require(!commitments[_commitment], "The commitment has been submitted");
    require(isKnownRoot(_root), "Cannot find your merkle root"); // Make sure to use a recent one
    require(wdVerifier.verifyProof(_proof, [uint256(_root), uint256(_voucher), uint256(_amount), uint256(_commitment), uint256(_recipient), uint256(_relayer), _fee, _refund]), "Invalid withdraw proof");

    vouchers[_voucher] = true;
    commitments[_commitment] = true;
    uint32 insertedIndex = _insert(_commitment);
    emit Deposit(_commitment, uint256(_amount), insertedIndex, block.timestamp);
    _processWithdraw(_amount, _recipient, _relayer, _fee);
    emit Withdrawal(_recipient, _voucher, _amount, _relayer, _fee, insertedIndex, block.timestamp);
  }

  function isSpent(bytes32 _voucher) public view returns(bool) {
    return vouchers[_voucher];
  }

  function isSpentArray(bytes32[] calldata _vouchers) external view returns(bool[] memory spent) {
    spent = new bool[](_vouchers.length);
    for(uint i = 0; i < _vouchers.length; i++) {
      if (isSpent(_vouchers[i])) {
        spent[i] = true;
      }
    }
  }

  function setFee(uint256 _bnbfee, uint256 _relayfee, uint256 _min) external onlyOperator {
    require(_relayfee < 100000, "repalyfee should less than 100000");
    bnbfee = _bnbfee;
    relayfee = _relayfee;
    min = _min;
  }

  function updateDPVerifier(address _newVerifier) external onlyOperator {
    dpVerifier = IDepositVerifier(_newVerifier);
  }

  function updateWDVerifier(address _newVerifier) external onlyOperator {
    wdVerifier = IWithdrawVerifier(_newVerifier);
  }

  
  function changeOperator(address _newOperator) external onlyOperator {
    operator = _newOperator;
  }

  

  function _processWithdraw(uint256 _amount, address payable _recipient, address payable _relayer, uint256 _fee) internal {
     uint256 relayamount = _amount * relayfee / 100000;
      uint256 reamount = _amount - relayamount; 
      
      _recipient.transfer(reamount - _fee);
      //token.transfer(_recipient, reamount - _fee);

      if (relayamount > 0) {
        _relayer.transfer(relayamount);
        //token.transfer(_relayer, relayamount);
      }
      
      if (_fee > 0) {
        _relayer.transfer(_fee); 
        //token.transfer(_relayer, _fee);
      }
  }
}
