// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}


interface IWhiteList {
    function add(address addr) external;
    function add(address [] memory addr) external;
    function remove(address addr) external;
    function remove(address [] memory addr) external;
    function isAllowed(address addr) external view returns(bool);

}

/**
    @notice can be used to conduct a simple english auction for an NFT with a fixed time limit
    @custom:warning This is an experimental, unaudited contract.
*/
contract EnglishAuction {
    //URI to retrieve information about the NFT being auctioned
    string public nftURI;
     //the ERC20 token used to bid
    IERC20 public biddingToken;
    //starting price for bidding (in smallest unit of the biddingToken
    uint public immutable startingPrice;
    //UNIX time that bidding starts. If in the past, bidding begins immediately
    uint public immutable startAt;
    //UNIX time that bidding ends. Calculated value.
    uint public immutable expiresAt;
    //duration of the bidding window in seconds
    uint public immutable duration; 
    //percent by which a new bid must exceed the current highest bid
    uint public immutable min_pct_bid_incr;

    struct Bid {
        uint amount;
        string btcAddress;
    } 

    //stores bids
    mapping(address => Bid) public bids;
    //stores the EVM address of the highest bidder
    address public highestBidder;
    //whitelist address
    IWhiteList public whitelist;

    //represends the current state of the auction
    enum AuctionState{ 
        NOT_STARTED, // before bidding starts
        RUNNING, // bidding period
        COMPLETE // one of the bidders settled after the auction ended
    }
    //the owner of the NFT being sold - trust based, as the NFT is expected to be a BTC ordinal on L1 Bitcoin
    address public seller;
    //whether or not the seller has already withdrawn the winning bid
    bool private sellerHasWithdrawn = false;

    // Events
    /**
        @notice emitted when there's a new successful bid
        @param ethAddress is the EVM address of the bidder
        @param btcAddress is the Bitcoin address where the Ordinal will be sent if this is the winning bid
        @param amount is the amount of biddingToken that was bid
        @param time is the current timestamp
    */
    event NewBid(address ethAddress, string btcAddress, uint amount, uint time);

    /**
        @dev ensure that a bidder is on the whitelist, if there's a whitelist
    */
    modifier ifAllowed() {
        if(address(whitelist) != address(0)){
            require(whitelist.isAllowed(msg.sender), "not permitted to bid");
        }
        _;
    }

    /**
        @param _startingPrice is the starting price or minimum bid for the auction in sats
        @param _nft is a URI link to the NFT so bidders know what they are buing
        @param _startTime is the unix time when the auction begins - if less than current blocktime, auction starts immediately
        @param _duration is the number of seconds for which bidding lasts
        @param _min_pct_bid_incr is the minimum percent increase of a new bid so that it exceeds the previous bid
        @param _whitelist is the whitelist address, 0x0 if no whitelist
    */
    constructor(uint _startingPrice, string memory _nft, uint _startTime, uint _duration, uint _min_pct_bid_incr, address _whitelist, address _token) {
        if(_startTime < block.timestamp) _startTime = block.timestamp; //prevent auction from starting in the past
        startingPrice = _startingPrice;
        startAt = _startTime;
        duration = _duration;
        expiresAt = duration + startAt;
        nftURI = _nft;
        seller = msg.sender;
        min_pct_bid_incr = _min_pct_bid_incr;
        whitelist = IWhiteList(_whitelist);
        biddingToken = IERC20(_token);
    }
    /** 
        @notice get the current state of the auction, see AuctionState enum, above for meanings.
        @return returns an enum representing the auction state
    */
    function getState() public view returns(AuctionState){
        if (block.timestamp < startAt) return AuctionState.NOT_STARTED;
        if (block.timestamp < expiresAt) return AuctionState.RUNNING;
        return AuctionState.COMPLETE;
    }

    /** 
        @notice called by a bidder to place a bid while the auction is running. Transfers tokens.
        @param _address is their bitcoin address that will recieve the ordinal if they are the winning bid, and settle in time
        @param _amount is the bid amount in the smallest unit of the bidding token 
        @dev assumes the bidding token reverts on failed transfer
        @dev if the bidder has an existing bid, the difference between the new bid and the old bid is sent to this contract
    */
    function bid(string memory _address, uint _amount) public ifAllowed{
        require(getState() == AuctionState.RUNNING, "auction is not running");
        require(_amount >= getMinBid(), "insufficient bid");
        //if they have a current bid, subtract the old bid from the amount of the new bid
        uint transferAmount = _amount - bids[msg.sender].amount;
        //transfer the amount of the bidding token
        biddingToken.transferFrom(msg.sender, address(this), transferAmount);
        bids[msg.sender].amount = _amount;
        bids[msg.sender].btcAddress = _address;
        highestBidder = msg.sender;
        emit NewBid(msg.sender, _address, _amount, block.timestamp);
    }

    /**
        @notice computes the current minimum bid amount
        @return the minimum bid in the smallest unit of the biddingToken
    */
    function getMinBid() public view returns(uint){
        if(highestBidder == address(0)) return startingPrice;
        else return bids[highestBidder].amount*(100+min_pct_bid_incr)/100;
    }
    
    /**
        @notice computes time remaining until bidding is over
        @return the number of seconds remaining in the auction
    */
    function getRemainingBidTime() public view returns(int){
        return int(expiresAt) - int(block.timestamp);
    }

    /**
        @notice seller can withdraw the winning bid amount exactly once, after the auction is complete
    */
    function sellerWithdraw() public{
        require(msg.sender == seller, "not authorized");
        require(getState() == AuctionState.COMPLETE, "not permitted");
        require(sellerHasWithdrawn == false, "already witdhdrawn");
        biddingToken.transfer(msg.sender, bids[highestBidder].amount);
        sellerHasWithdrawn = true;
    }
    /**
        @notice unsuccessful bidders can withdraw their bid after the auction is complete
    */
    function unsuccessfulBidWithdraw() public{
        require(msg.sender != highestBidder, "not authorized");
        require(getState() == AuctionState.COMPLETE, "not permitted");
        biddingToken.transfer(msg.sender, bids[msg.sender].amount);
        bids[msg.sender].amount = 0;
    }
}

