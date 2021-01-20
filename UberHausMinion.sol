// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.5;

interface IERC20 { // interface for erc20 approve/transfer
    function balanceOf(address who) external view returns (uint256);
    
    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
    
    function approve(address spender, uint256 amount) external returns (bool);
}

library SafeMath { // arithmetic wrapper for unit under/overflow check
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b);
        return c;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0);
        uint256 c = a / b;
        return c;
    }
}


contract ReentrancyGuard { // call wrapper for reentrancy check
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}


abstract contract Context {
    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () internal {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}


interface IMOLOCH { // brief interface for moloch dao v2

    function depositToken() external view returns (address);
    
    function tokenWhitelist(address token) external view returns (bool);
    
    function getProposalFlags(uint256 proposalId) external view returns (bool[6] memory);
    
    function members(address user) external view returns (address, uint256, uint256, bool, uint256, uint256);
    
    function userTokenBalances(address user, address token) external view returns (uint256);
    
    function cancelProposal(uint256 proposalId) external;

    function submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        string calldata details
    ) external returns (uint256);
    
    function updateDelegateKey(address newDelegateKey) external; 
    
    function withdrawBalance(address token, uint256 amount) external;
}


contract UberHausMinion is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    
    IMOLOCH public moloch;
    
    address public dao; // dao that manages minion 
    address public uberHaus; // address of uberHaus 
    address[] public delegateList; // list of child dao delegates
    address public currentDelegate;
    uint256 public delegateRewardsFactor; // percent of HAUS given to delegates 
    uint256 public hausBalance;
    string public DESC; //description of minion
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern
    
    address public constant GUILD = address(0xdead);
    address public constant REWARDS = address(0xfeed);
    address public HAUS; // HAUS token address @dev - will make this a constant for production 

    mapping(address => Delegate) public delegates; // delegates of child dao
    mapping(uint256 => Action) public actions; // proposalId => Action
    mapping(uint256 => Appointment) public appointments; // proposalId => Appointment
    mapping(address => mapping(address => uint256)) public userTokenBalances;

    
    struct Delegate {
        uint256 appointmentTime;
        uint256 retireTime;
        bool serving; 
        bool impeached; 
    }
    
    struct Action {
        address dao;
        uint256 value;
        address token;
        address to;
        address proposer;
        bool executed;
        bytes data;
    }
    
    struct Appointment {
        address dao;
        address nominee;
        uint256 retireTime;
        address proposer;
        bool executed;
    }

    event ProposeAction(uint256 proposalId, address proposer);
    event ProposeAppointment(uint256 proposalId, address proposer, address nominee, uint256 retireTime);
    event ExecuteAction(uint256 proposalId, address executor);
    event DelegateAppointed(uint256 proposalId, address executor, address currentDelegate);
    event Impeachment(address delegate, address impeacher);
    event DoWithdraw(address targetDao, address token, uint256 amount);
    event HausWithdraw(address token, uint256 amount);
    event PulledFunds(address token, uint256 amount);
    event RewardsClaimed(address currentDelegate, uint256 amount);
    event Canceled(uint256 proposalId, uint8 proposalType);
    event TokensCollected(address token, uint256 amountToCollect);

    
    modifier memberOnly() {
        require(isMember(msg.sender), "Minion::not member");
        _;
    }
    
    modifier delegateOnly() {
        require(delegates[msg.sender].serving == true, "Minion::not member");
        _;
    }
    
    function init(
        address _dao, 
        address _uberHaus, 
        address _Haus,
        string memory _DESC
    ) external {
        moloch = IMOLOCH(_dao);
        dao = _dao;
        uberHaus = _uberHaus;
        HAUS = _Haus;
        DESC = _DESC;
        initialized = true; 
    }
    
    //  -- Withdraw Functions --

    function doWithdraw(address targetDao, address token, uint256 amount) external memberOnly {
        // Withdraws funds from any Moloch (incl. UberHaus or the minion owner DAO) into this Minion
        IMOLOCH(targetDao).withdrawBalance(token, amount); // withdraw funds from DAO
        emit DoWithdraw(targetDao, token, amount);
    }
    
    function hausWithdraw (uint256 amount) external memberOnly {
        /*
        ** Withdraws $HAUS from UberHaus into Minion
        ** Splits $HAUS between the GUILD and REWARDS for delegates
        */ 
        IMOLOCH(uberHaus).withdrawBalance(HAUS, amount);
        
        uint256 delegateReward = amount.mul(delegateRewardsFactor.div(100));
        uint256 daoAmt = amount - delegateReward;
        
        unsafeAddToBalance(GUILD, HAUS, daoAmt);
        unsafeAddToBalance(REWARDS, HAUS, delegateReward);

        emit HausWithdraw(HAUS, amount);
    }
    
    function pullGuildFunds(address token, uint256 amount) external delegateOnly {
        // Pulls tokens from the Minion into its master moloch 
        require(moloch.tokenWhitelist(token), "token !whitelisted by master dao");
        require(amount <= getUserTokenBalance(GUILD, token));
        
        IERC20(token).transfer(address(moloch), amount);
        unsafeSubtractFromBalance(GUILD, token, amount);
        
        emit PulledFunds(token, amount);
    }
    
    function claimRewards(uint256 amount) external delegateOnly {
        // Pulls tokens from the Minion into its master moloch 
        require(amount <= getUserTokenBalance(GUILD, HAUS));
        require(!delegates[currentDelegate].impeached, "delegate impeached");
        
        IERC20(HAUS).transfer(address(currentDelegate), amount);
        unsafeSubtractFromBalance(GUILD, HAUS, amount);
        
        emit RewardsClaimed(currentDelegate, amount);
    }
    
    //  -- Proposal Functions --
    
    function proposeAction(
        address targetDao,
        address actionTo,
        address token,
        uint256 actionValue,
        bytes calldata actionData,
        string calldata details
    ) external memberOnly returns (uint256) {
        // No calls to zero address allows us to check that proxy submitted
        // the proposal without getting the proposal struct from parent moloch
        require(actionTo != address(0), "invalid actionTo");

        uint256 proposalId = IMOLOCH(targetDao).submitProposal(
            address(this),
            0,
            0,
            0,
            token,
            0,
            token,
            details
        );

        Action memory action = Action({
            dao: targetDao,
            value: actionValue,
            token: token,
            to: actionTo,
            proposer: msg.sender,
            executed: false,
            data: actionData
        });

        actions[proposalId] = action;

        emit ProposeAction(proposalId, msg.sender);
        return proposalId;
    }

    function executeAction(uint256 proposalId) external returns (bytes memory) {
        Action memory action = actions[proposalId];
        bool[6] memory flags = IMOLOCH(action.dao).getProposalFlags(proposalId);

        require(action.to != address(0), "invalid proposalId");
        require(!action.executed, "action executed");
        require(getUserTokenBalance(GUILD, action.token) >= action.value, "insufficient eth");
        require(flags[2], "proposal not passed");

        // execute call
        actions[proposalId].executed = true;
        (bool success, bytes memory retData) = action.to.call{value: action.value}(action.data);
        require(success, "call failure");
        emit ExecuteAction(proposalId, msg.sender);
        return retData;
    }
    
    function nominateDelegate(
        address targetDao, //default would be UberHaus  
        address nominee,
        uint256 retireTime,
        string calldata details
    ) external memberOnly returns (uint256) {
        // No calls to zero address allows us to check that proxy submitted
        // the proposal without getting the proposal struct from parent moloch
        require(targetDao != address(0), "invalid actionTo");

        uint256 proposalId = IMOLOCH(targetDao).submitProposal(
            address(this),
            0,
            0,
            0,
            HAUS, // includes whitelisted token to avoid errors on DAO end
            0,
            HAUS,
            details
        );

        Appointment memory appointment = Appointment({
            dao: targetDao,
            nominee: nominee,
            retireTime: retireTime,
            proposer: msg.sender,
            executed: false
        });

        appointments[proposalId] = appointment;

        emit ProposeAppointment(proposalId, msg.sender, nominee, retireTime);
        return proposalId;
    }

    function executeAppointment(uint256 proposalId) external returns (address) {
        Appointment memory appointment = appointments[proposalId];
        bool[6] memory flags = IMOLOCH(moloch).getProposalFlags(proposalId);

        require(appointment.dao != address(0), "invalid delegation address");
        require(!appointment.executed, "appointment already executed");
        require(flags[2], "proposal not passed");

        // execute call
        appointment.executed = true;
        IMOLOCH(uberHaus).updateDelegateKey(appointment.nominee);
        delegates[appointment.nominee] = Delegate(block.timestamp, appointment.retireTime, true, false);
        delegateList.push(appointment.nominee);
        currentDelegate = appointment.nominee;
        
        emit DelegateAppointed(proposalId, msg.sender, appointment.nominee);
        return appointment.nominee;
    }
    
    function cancelAction(uint256 _proposalId, uint8 _type) external {
        if(_type == 1){
            Action memory action = actions[_proposalId];
            require(msg.sender == action.proposer, "not proposer");
            delete actions[_proposalId];
        } else if (_type == 2){
            Appointment memory appointment = appointments[_proposalId];
            require(msg.sender == appointment.proposer, "not proposer");
            delete appointments[_proposalId];
        } 
        
        emit Canceled(_proposalId, _type);
        moloch.cancelProposal(_proposalId);
    }
    
    //  -- Emergency Functions --
    
    function impeachDelegate(address delegate) external memberOnly {
        require(!delegates[currentDelegate].impeached, "already impeached");
        delegates[currentDelegate].impeached = true; 
        IMOLOCH(uberHaus).updateDelegateKey(address(this));
        
        emit Impeachment(delegate, msg.sender);
    }
    
    
    //  -- Helper Functions --
    function collectTokens(address token) external {
        uint256 totalBalance = (userTokenBalances[GUILD][token]) + (userTokenBalances[REWARDS][token]);
        uint256 amountToCollect = IERC20(token).balanceOf(address(this)) - totalBalance; 
        
        // only collect if 1) there are tokens to collect and 2) token is whitelisted in the Moloch (child dao)
        require(amountToCollect > 0, "no tokens");
        require(moloch.tokenWhitelist(token), "not whitelisted");
        
        unsafeAddToBalance(GUILD, token, amountToCollect);

        emit TokensCollected(token, amountToCollect);
    }
    
    function isMember(address user) public view returns (bool) {
        
        (, uint shares,,,,) = moloch.members(user);
        return shares > 0;
    }
    
    function getUserTokenBalance(address user, address token) public view returns (uint256) {
        return userTokenBalances[user][token];
    }

    function unsafeAddToBalance(address user, address token, uint256 amount) internal {
        userTokenBalances[user][token] += amount;
    }

    function unsafeSubtractFromBalance(address user, address token, uint256 amount) internal {
        userTokenBalances[user][token] -= amount;
    }
}
    
    
    







