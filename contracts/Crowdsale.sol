import './SafeMath.sol';
import './Ownable.sol';
import './MoedaToken.sol';

pragma solidity ^0.4.8;

/// @title Moeda crowdsale
contract Crowdsale is Ownable, SafeMath {
    bool public crowdsaleClosed;        // whether the crowdsale has been closed 
                                        // manually
    address public wallet;              // recipient of all crowdsale funds
    MoedaToken public moedaToken;       // token that will be sold during sale
    uint256 public etherReceived;       // total ether received
    uint256 public totalTokensSold;     // number of tokens sold
    uint256 public startBlock;          // block where sale starts
    uint256 public endBlock;            // block where sale ends

    // used to scale token amounts to 18 decimals
    uint256 public constant TOKEN_MULTIPLIER = 10 ** 18;

    // number of tokens sold during presale
    uint256 public constant PRESALE_TOKEN_AMOUNT = 5000000 * TOKEN_MULTIPLIER;
    
    // smallest possible donation
    uint256 public constant DUST_LIMIT = 200 finney;

    // token creation rates
    uint256 public constant TIER1_RATE = 6 finney;
    uint256 public constant TIER2_RATE = 8 finney;
    uint256 public constant TIER3_RATE = 12 finney;

    // limits for each pricing tier (how much can be bought)
    uint256 public constant TIER1_CAP =  30000 ether;
    uint256 public constant TIER2_CAP =  70000 ether;
    uint256 public constant TIER3_CAP = 130000 ether; // Total ether cap

    event Buy(address indexed donor, uint256 amount, uint256 tokenAmount);

    modifier onlyDuringSale() {
        if (crowdsaleClosed) {
            throw;
        }

        if (block.number < startBlock) {
            throw;
        }

        if (block.number >= endBlock) {
            throw;
        }
        _;
    }

    /// @dev Initialize a new Crowdsale contract
    /// @param _wallet address of multisig wallet that will store received ether
    /// @param _startBlock block at which to start the sale
    /// @param _endBlock block at which to end the sale
    function Crowdsale(address _wallet, uint _startBlock, uint _endBlock) {
        if (_wallet == address(0)) throw;
        if (_startBlock <= block.number) throw;
        if (_endBlock <= _startBlock) throw;
        
        crowdsaleClosed = false;
        wallet = _wallet;
        moedaToken = new MoedaToken();
        startBlock = _startBlock;
        endBlock = _endBlock;
    }

    /// @dev Determine the lowest rate to acquire tokens given an amount of 
    /// donated ethers
    /// @param totalReceived amount of ether that has been received
    /// @return pair of the current tier's donation limit and a token creation rate
    function getLimitAndRate(uint256 totalReceived)
    constant returns (uint256, uint256) {
        uint256 limit = 0;
        uint256 rate = 0;

        if (totalReceived < TIER1_CAP) {
            limit = TIER1_CAP;
            rate = TIER1_RATE;
        }
        else if (totalReceived < TIER2_CAP) {
            limit = TIER2_CAP;
            rate = TIER2_RATE;
        }
        else if (totalReceived < TIER3_CAP) {
            limit = TIER3_CAP;
            rate = TIER3_RATE;
        } else {
            throw; // this shouldn't happen
        }

        return (limit, rate);
    }

    /// @dev Determine how many tokens we can get from each pricing tier, in case a
    /// donation's amount overlaps multiple pricing tiers.
    /// 1. determine cheapest token price
    /// 2. determine how many tokens can be bought at this price
    /// 3. subtract spent ether from requested amount
    /// 4. if there is any ether left, start over from 1, with the remaining ether
    /// 5. return the amount of tokens bought
    /// @param totalReceived ether received by contract plus spent by this donation
    /// @param requestedAmount total ether to spend on tokens in a donation
    /// @return amount of tokens to get for the requested ether donation
    function getTokenAmount(uint256 totalReceived, uint256 requestedAmount) 
    constant returns (uint256) {
        if (requestedAmount == 0) return 0;
        uint256 limit = 0;
        uint256 rate = 0;
        (limit, rate) = getLimitAndRate(totalReceived);

        uint256 maxETHSpendableInTier = safeSub(limit, totalReceived);
        uint256 amountToSpend = min256(maxETHSpendableInTier, requestedAmount);
        uint256 tokensToReceiveAtCurrentPrice = safeDiv(
            safeMul(amountToSpend, TOKEN_MULTIPLIER), rate);
        uint256 additionalTokens = getTokenAmount(
            safeAdd(totalReceived, amountToSpend),
            safeSub(requestedAmount, amountToSpend));

        return safeAdd(tokensToReceiveAtCurrentPrice, additionalTokens);
    }

    /// grant tokens to buyer when we receive ether
    /// @dev buy tokens, only usable while crowdsale is active
    function () payable onlyDuringSale {
        if (msg.value < DUST_LIMIT) throw;
        if (safeAdd(etherReceived, msg.value) > TIER3_CAP) throw;
        if (!wallet.send(msg.value)) throw;

        uint256 tokenAmount = getTokenAmount(etherReceived, msg.value);

        if (!moedaToken.create(msg.sender, tokenAmount)) throw;
        etherReceived = safeAdd(etherReceived, msg.value);
        totalTokensSold = safeAdd(totalTokensSold, tokenAmount);
        Buy(msg.sender, msg.value, tokenAmount);
    }

    /// @dev close the crowdsale manually and unlock the tokens
    /// this will only be successful if not already executed,
    /// if endBlock has been reached, or if the cap has been reached
    function finalize() onlyOwner {
        if (block.number < startBlock) throw;
        if (crowdsaleClosed) throw;

        // if amount remaining is less than dust limit, allow sale to be
        // completed early
        uint256 minCapRequirement = safeAdd(etherReceived, DUST_LIMIT);
        if (block.number < endBlock && minCapRequirement < TIER3_CAP) throw;

        // create and assign presale tokens to team wallet
        if (!moedaToken.create(wallet, PRESALE_TOKEN_AMOUNT)) throw;

        // unlock tokens for spending
        if(!moedaToken.unlock()) throw;
        crowdsaleClosed = true;
    }
}
