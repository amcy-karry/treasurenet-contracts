// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../interfaces/IProducer.sol";
import "../ProductionData.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract OilData is ProductionData {
    using Counters for Counters.Counter;

    /**
     * @dev Initializes the contract with required parameters.
     * @param _treasureKind The type of treasure this contract handles.
     * @param _oracleContract Address of the oracle contract.
     * @param _rolesContract Address of the roles contract.
     * @param _parameterInfoContract Address of the parameter info contract.
     * @param _producerContract Address of the producer contract.
     * @param _tatContract Address of the TAT contract.
     */
    function initialize(
        string memory _treasureKind,
        address _oracleContract,
        address _rolesContract,
        address _parameterInfoContract,
        address _producerContract,
        address _tatContract
    ) public initializer {
        __ProductionDataInitialize(
            _treasureKind,
            _oracleContract,
            _rolesContract,
            _parameterInfoContract,
            _producerContract,
            _tatContract
        );
    }

    function receiveTrustedProductionData(
        bytes32 _requestId,
        bytes32 _uniqueId,
        ProduceData memory _produceData
    ) external override onlyFeeder onlyWhenActive(_uniqueId) {
        require(
            _requestId == _requestIdsToPullTrustedData[_uniqueId],
            "invalid oracle request id,not for production data"
        );
        require(_produceData.month != 0, "production data month cant be zero");

        IProducer.ProducerCore memory thisProducer = _getProducer(_uniqueId);

        if (
            _trustedProduceData[_produceData.month][_uniqueId].account ==
            thisProducer.owner
        ) {
            _trustedProduceData[_produceData.month][_uniqueId]
                .amount = _produceData.amount;
        } else {
            // ProduceData memory data;
            _produceData.account = thisProducer.owner;
            _produceData.amount = _produceData.amount; //TODO: The same on both sides
            _trustedProduceData[_produceData.month][_uniqueId] = _produceData;
        }

        emit TrustedProductionData(
            TREASURE_KIND,
            _uniqueId,
            _produceData.month,
            _produceData.amount
        );
    }

    // product add by producer
    function setProductionData(
        bytes32 _uniqueId,
        ProduceData memory _produceData
    ) public override onlyWhenActive(_uniqueId) {
        IProducer.ProducerCore memory thisProducer = _getProducer(_uniqueId);
        require(_msgSender() == thisProducer.owner, "must be the producer");
        require(_produceData.month > 0, "zero production month");
        require(_produceData.month < 10000, "month format is not YYMM");
        require(_produceData.date > 0, "zero production date");
        require(_produceData.date < 1000000, "date format is not YYMMDD");
        require(_produceData.amount > 0, "zero production amount");

        uint256 discount = _parameterInfo.getPriceDiscountConfig(
            thisProducer.API,
            thisProducer.sulphur
        );

        // Market value
        /* Decimal design: Multiply the 'amount' parameter by 10000 for the input, and multiply the unit price by 10000 for the input */
        uint256 price = ((_produceData.amount *
            _getAssetValue(_produceData.date) *
            discount) * 1e18) /
            10000 /
            10000 /
            10000;

        bool _exist = false;
        for (
            uint256 i = 0;
            i < _uploadedProduceData[_produceData.month].length;
            i++
        ) {
            if (
                _uploadedProduceData[_produceData.month][i].uniqueId ==
                _uniqueId
            ) {
                _exist = true;
                require(
                    _uploadedProduceData[_produceData.month][i].status ==
                        ProduceDataStatus.UNAUDITED,
                    "production data that has been audited."
                );
                _uploadedProduceData[_produceData.month][i].amount =
                    _uploadedProduceData[_produceData.month][i].amount +
                    _produceData.amount;
                _uploadedProduceData[_produceData.month][i].price =
                    _uploadedProduceData[_produceData.month][i].price +
                    price;
                break;
            }
        }
        if (!_exist) {
            _produceData.uniqueId = _uniqueId;
            _produceData.account = thisProducer.owner;
            _produceData.price = price;
            _produceData.counterId = _entityCounter.current();
            // inc++
            _produceData.status = ProduceDataStatus.UNAUDITED;
            _uploadedProduceData[_produceData.month].push(_produceData);
        }

        _entityCounter.increment();

        emit ProducerProductionData(
            TREASURE_KIND,
            _uniqueId,
            _produceData.month,
            _produceData.date,
            _produceData.amount,
            price
        );
    }

    function getProductionData(
        bytes32 _uniqueId,
        uint256 month
    ) public view override returns (ProduceData memory) {
        ProduceData memory data;
        for (uint256 i = 0; i < _uploadedProduceData[month].length; i++) {
            if (_uploadedProduceData[month][i].uniqueId == _uniqueId) {
                data = _uploadedProduceData[month][i];
                break;
            }
        }
        return data;
    }

    function _clearing(
        bytes32 _uniqueId,
        uint256 _month
    ) internal override returns (bool) {
        ProduceData memory uploaded;
        uint256 index;
        for (uint256 i = 0; i < _uploadedProduceData[_month].length; i++) {
            if (_uploadedProduceData[_month][i].uniqueId == _uniqueId) {
                uploaded = _uploadedProduceData[_month][i];
                index = i;
            }
        }
        require(
            uploaded.account != address(0),
            "cleared or product data not found at this month"
        );
        require(
            uploaded.status == ProduceDataStatus.UNAUDITED,
            "this product data already audited"
        );

        ProduceData storage trusted = _trustedProduceData[_month][_uniqueId];
        require(
            trusted.account != address(0),
            "cleared or product data not found at this month"
        );

        emit VerifiedProduction(_uniqueId, _month, trusted.amount);

        // compare produce data within `uploaded` and `trusted`
        if (uploaded.amount > trusted.amount) {
            uint256 nprice = (uploaded.price * trusted.amount) /
                uploaded.amount;
            uploaded.price = nprice;

            uint256 deviation = ((uploaded.amount - trusted.amount) *
                100 *
                100) / trusted.amount;
            /* For precision, amplify 'deviation' by 100 times */
            if (deviation > 3000) {
                deviation = 10000;
            }
            //  Only penalize in case of >10% deviation
            if (deviation > 1000) {
                uint256 penaltyCost = _penalty(
                    uploaded.account,
                    nprice,
                    deviation
                );
                emit ClearingPenalty(
                    TREASURE_KIND,
                    _uniqueId,
                    _month,
                    penaltyCost,
                    deviation
                );
                // FAILED
                uploaded.status = ProduceDataStatus.FAILED;
            } else {
                uploaded.status = ProduceDataStatus.FINISHED;
            }
        } else {
            uploaded.status = ProduceDataStatus.FINISHED;
        }
        require(
            _rewardByShare(_uniqueId, uploaded.price) == uploaded.price,
            "total minted must equal to trusted.amount"
        );
        emit ClearingReward(TREASURE_KIND, _uniqueId, _month, uploaded.price);

        _uploadedProduceData[_month][index] = uploaded;

        return true;
    }

    function _afterClearing(
        bytes32 _uniqueId,
        uint256 _month
    ) internal override {}

    function _rewardByShare(
        bytes32 uniqueId,
        uint256 total
    ) internal returns (uint256) {
        (address[] memory accounts, uint256[] memory amounts) = _producer
            .calculateRewards(uniqueId, total);
        return _reward(uniqueId, accounts, amounts);
    }
}
