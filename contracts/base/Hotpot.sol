// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IHotpot} from "./interface/IHotpot.sol";
import {IAxelarGateway} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";
import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {StringToAddress, AddressToString} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/utils/AddressString.sol";

import {SchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/SchemaResolver.sol";
import {IEAS, Attestation, AttestationRequest, AttestationRequestData} from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";

contract Hotpot is
    IHotpot,
    OwnableUpgradeable,
    PausableUpgradeable,
    AxelarExecutable,
    SchemaResolver
{
    using StringToAddress for string;
    using AddressToString for address;
    uint256 public potLimit;
    uint256 public currentPotSize;
    uint256 public raffleTicketCost;
    mapping(address => Prize) public claimablePrizes;
    mapping(uint256 => RequestStatus) public randomRequests;
    mapping(uint16 => uint32[]) public winningTicketIds;
    uint256 public lastRequestId;
    uint128 private claimWindow;
    uint16 public numberOfWinners;
    uint16 public fee; // 100 = 1%, 10000 = 100%;
    uint16 public tradeFee; // the percent of a trade amount that goes to the pot as pure ether
    uint32 public lastRaffleTicketId;
    uint32 public potTicketIdStart; // start of current pot ticket range
    uint32 public potTicketIdEnd; // end of current pot ticket range
    uint32 public nextPotTicketIdStart;
    uint16 public currentPotId;
    address private marketplace;
    address private operator;
    uint256 constant MULTIPLIER = 10000;
    bytes32 public immutable i_schemaId;
    IEAS public immutable i_eas;

    mapping(string => address) public sourceChains;

    modifier onlyMarketplaceOrGateway() {
        require(
            msg.sender == marketplace || msg.sender == address(gateway),
            "Caller is not the marketplace contract"
        );

        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Caller must be the operator");
        _;
    }

    constructor(
        address _gateway,
        IEAS eas,
        bytes32 _schemaId
    ) AxelarExecutable(_gateway) SchemaResolver(eas) {
        i_eas = eas;
        i_schemaId = _schemaId;
        _disableInitializers();
    }

    function addSourceChain(
        string calldata _sourceChain,
        address _sourceChainAddress
    ) external onlyOwner {
        require(
            _sourceChainAddress != address(0),
            "Invalid source chain address"
        );
        require(bytes(_sourceChain).length > 0, "Invalid source chain");
        sourceChains[_sourceChain] = _sourceChainAddress;
    }

    function initialize(
        address _owner,
        InitializeParams calldata params
    ) external initializer {
        __Ownable_init();
        __Pausable_init();
        transferOwnership(_owner);

        potLimit = params.potLimit;
        raffleTicketCost = params.raffleTicketCost;
        claimWindow = params.claimWindow;
        numberOfWinners = params.numberOfWinners;
        fee = params.fee;
        tradeFee = params.tradeFee;
        lastRaffleTicketId = 1;
        potTicketIdStart = 1;
        potTicketIdEnd = 1;
        lastRequestId = 1;
        currentPotId = 1;
        marketplace = params.marketplace;
        operator = params.operator;
    }

    function executeTrade(
        uint256 _amountInWei,
        address _buyer,
        address _seller,
        uint256 _buyerPendingAmount,
        uint256 _sellerPendingAmount,
        uint256 crossChainAmount
    ) public payable onlyMarketplaceOrGateway whenNotPaused {
        require(_buyer != _seller, "Buyer and seller must be different");
        require(
            crossChainAmount > 0 || msg.value > 0,
            "No trade fee transferred (msg.value)"
        );
        uint256 potValueDelta = ((msg.value + crossChainAmount) *
            (MULTIPLIER - fee)) / MULTIPLIER;
        uint256 _currentPotSize = currentPotSize;
        uint256 _potLimit = potLimit;
        uint256 _raffleTicketCost = raffleTicketCost;
        uint32 _lastRaffleTicketIdBefore = lastRaffleTicketId;

        uint32 buyerTickets = uint32(
            (_buyerPendingAmount + _amountInWei) / _raffleTicketCost
        );
        uint32 sellerTickets = uint32(
            (_sellerPendingAmount + _amountInWei) / _raffleTicketCost
        );
        uint256 _newBuyerPendingAmount = (_buyerPendingAmount + _amountInWei) %
            _raffleTicketCost;
        uint256 _newSellerPendingAmount = (_sellerPendingAmount +
            _amountInWei) % _raffleTicketCost;

        _generateTickets(
            _buyer,
            _seller,
            buyerTickets,
            sellerTickets,
            _newBuyerPendingAmount,
            _newSellerPendingAmount
        );

        /*
            Request Chainlink random winners if the Pot is filled 
         */
        if (_currentPotSize + potValueDelta >= _potLimit) {
            uint32 _potTicketIdEnd = _calculateTicketIdEnd(
                _lastRaffleTicketIdBefore
            );
            potTicketIdEnd = _potTicketIdEnd;
            potTicketIdStart = nextPotTicketIdStart;
            nextPotTicketIdStart = _potTicketIdEnd + 1; // starting ticket of the next Pot
            // The remainder goes to the next pot
            currentPotSize = (_currentPotSize + potValueDelta) % _potLimit;
            _requestRandomWinners();
        } else {
            currentPotSize += potValueDelta;
        }
    }

    function executeRaffle(
        address[] calldata _winners,
        uint128[] calldata _amounts
    ) external onlyOperator {
        uint _potLimit = potLimit;
        require(
            _winners.length == _amounts.length,
            "Winners and their amounts mismatch"
        );
        require(
            _winners.length == numberOfWinners,
            "Must be equal to numberofWinners"
        );
        // for testing
        // require(address(this).balance >= _potLimit, "The pot is not filled");

        uint sum = 0;
        for (uint i; i < _amounts.length; i++) {
            Prize storage userPrize = claimablePrizes[_winners[i]];
            userPrize.deadline = uint128(block.timestamp + claimWindow);
            userPrize.amount = userPrize.amount + _amounts[i];
            sum += _amounts[i];
        }
        require(sum <= _potLimit);

        emit WinnersAssigned(_winners, _amounts);
    }

    function claim() external payable whenNotPaused {
        address payable user = payable(msg.sender);
        Prize memory prize = claimablePrizes[user];
        require(prize.amount > 0, "No available winnings");
        require(block.timestamp < prize.deadline, "Claim window is closed");

        claimablePrizes[user].amount = 0;
        user.transfer(prize.amount);
        AttestationRequestData memory requestData = AttestationRequestData(
            address(this),
            type(uint64).max,
            false,
            bytes32(0),
            abi.encode(address(this), user, prize.amount, block.timestamp),
            msg.value
        );
        AttestationRequest memory request = AttestationRequest(
            i_schemaId,
            requestData
        );
        bytes32 attestationUID = i_eas.attest(request);
        emit Claim(user, prize.amount, attestationUID);
    }

    function getWinningTicketIds(
        uint16 _potId
    ) external view returns (uint32[] memory) {
        return winningTicketIds[_potId];
    }

    function setMarketplace(address _newMarketplace) external onlyOwner {
        require(marketplace != _newMarketplace, "Address didn't change");
        marketplace = _newMarketplace;
        emit MarketplaceUpdated(_newMarketplace);
    }

    function setOperator(address _newOperator) external onlyOwner {
        require(operator != _newOperator, "Address didn't change");
        operator = _newOperator;
        emit OperatorUpdated(_newOperator);
    }

    function setRaffleTicketCost(
        uint256 _newRaffleTicketCost
    ) external onlyOwner {
        require(
            raffleTicketCost != _newRaffleTicketCost,
            "Cost must be different"
        );
        require(_newRaffleTicketCost > 0, "Raffle cost must be non-zero");
        raffleTicketCost = _newRaffleTicketCost;
    }

    function setPotLimit(uint256 _newPotLimit) external onlyOwner {
        require(potLimit != _newPotLimit, "Pot limit must be different");
        potLimit = _newPotLimit;
    }

    function _generateTickets(
        address _buyer,
        address _seller,
        uint32 buyerTickets,
        uint32 sellerTickets,
        uint256 _newBuyerPendingAmount,
        uint256 _newSellerPendingAmount
    ) internal {
        uint32 buyerTicketIdStart;
        uint32 buyerTicketIdEnd;
        uint32 sellerTicketIdStart;
        uint32 sellerTicketIdEnd;

        /*
            Assigning newly generated ticket ranges 
        */
        if (buyerTickets > 0) {
            buyerTicketIdStart = lastRaffleTicketId + 1;
            buyerTicketIdEnd = buyerTicketIdStart + buyerTickets - 1;
        }
        if (sellerTickets > 0) {
            bool buyerGetsNewTickets = buyerTicketIdEnd > 0;
            sellerTicketIdStart = buyerGetsNewTickets
                ? buyerTicketIdEnd + 1
                : lastRaffleTicketId + 1;
            sellerTicketIdEnd = sellerTicketIdStart + sellerTickets - 1;
        }
        lastRaffleTicketId += buyerTickets + sellerTickets;

        emit GenerateRaffleTickets(
            _buyer,
            _seller,
            buyerTicketIdStart,
            buyerTicketIdEnd,
            sellerTicketIdStart,
            sellerTicketIdEnd,
            _newBuyerPendingAmount,
            _newSellerPendingAmount
        );
    }

    function _calculateTicketIdEnd(
        uint32 _lastRaffleTicketIdBefore
    ) internal view returns (uint32 _ticketIdEnd) {
        uint256 _raffleTicketCost = raffleTicketCost;
        uint256 _ethDeltaNeededToFillPot = ((potLimit - currentPotSize) *
            MULTIPLIER) / (MULTIPLIER - fee);
        uint256 _tradeAmountNeededToFillPot = (_ethDeltaNeededToFillPot *
            MULTIPLIER) / tradeFee;
        // First calculate tickets needed to fill the pot
        uint32 ticketsNeeded = uint32(
            _tradeAmountNeededToFillPot / _raffleTicketCost
        ) * 2;

        if (_tradeAmountNeededToFillPot % _raffleTicketCost > 0) {
            ticketsNeeded += 1;
        }

        return _lastRaffleTicketIdBefore + ticketsNeeded;
    }

    function _requestRandomWinners() internal {
        uint requestId = ++lastRequestId;
        randomRequests[requestId].exists = true;
        emit RandomWordRequested(requestId, potTicketIdStart, potTicketIdEnd);
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256 _salt
    ) external onlyOperator {
        uint32 rangeFrom = potTicketIdStart;
        uint32 rangeTo = potTicketIdEnd;

        randomRequests[_requestId] = RequestStatus({
            fullfilled: true,
            exists: true,
            randomWord: _salt
        });

        uint256 n_winners = numberOfWinners;
        uint32[] memory derivedRandomWords = new uint32[](n_winners);
        uint256 randomWord = _generateRandomFromSalt(_salt);
        derivedRandomWords[0] = _normalizeValueToRange(
            randomWord,
            rangeFrom,
            rangeTo
        );
        uint256 nextRandom;
        uint32 nextRandomNormalized;
        for (uint256 i = 1; i < n_winners; i++) {
            nextRandom = uint256(keccak256(abi.encode(randomWord, i)));
            nextRandomNormalized = _normalizeValueToRange(
                nextRandom,
                rangeFrom,
                rangeTo
            );
            derivedRandomWords[i] = _incrementRandomValueUntilUnique(
                nextRandomNormalized,
                derivedRandomWords
            );
        }

        winningTicketIds[currentPotId] = derivedRandomWords;
        currentPotId++;
        emit RandomnessFulfilled(currentPotId, _salt);
    }

    function _executeWithToken(
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 tokenAmount
    ) internal override {
        require(
            sourceChains[sourceChain] == sourceAddress.toAddress(),
            "Invalid source chain or address"
        );
        (uint256 _totalFee, address _buyer, address _seller) = abi.decode(
            payload,
            (uint256, address, address)
        );
        executeTrade(_totalFee, _buyer, _seller, 0, 0, tokenAmount);
    }

    function _generateRandomFromSalt(
        uint256 _salt
    ) internal view returns (uint256 _random) {
        return uint256(keccak256(abi.encode(_salt, block.timestamp)));
    }

    function _normalizeValueToRange(
        uint256 _value,
        uint32 _rangeFrom,
        uint32 _rangeTo
    ) internal pure returns (uint32 _scaledValue) {
        _scaledValue = (uint32(_value) % (_rangeTo - _rangeFrom)) + _rangeFrom; // from <= x <= to
    }

    function _incrementRandomValueUntilUnique(
        uint32 _random,
        uint32[] memory _randomWords
    ) internal pure returns (uint32 _uniqueRandom) {
        _uniqueRandom = _random;
        for (uint i = 0; i < _randomWords.length; ) {
            if (_uniqueRandom == _randomWords[i]) {
                unchecked {
                    _uniqueRandom++;
                    i = 0;
                }
            } else {
                unchecked {
                    i++;
                }
            }
        }
    }

    function onAttest(
        Attestation calldata attestation,
        uint256 /*value*/
    ) internal pure override returns (bool) {
        return true;
    }

    function onRevoke(
        Attestation calldata /*attestation*/,
        uint256 /*value*/
    ) internal pure override returns (bool) {
        return true;
    }
}
