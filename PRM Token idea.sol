// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "../interfaces/IPrmToken.sol";
import "../interfaces/IPrimisBond.sol";
import "hardhat/console.sol";

error ZeroAddress();
error InvalidParam();
error InvalidEarlyEpoch();
error ZeroFeeCollected();
error ThreeMonthVestingNotComplete();
error ZeroAmount();
error MoreThanMintAmount();
error VestingNotCompleted();
error WaitingTimeNotCompleted();

/**
 * @title PrmToken contract
 * @notice Implements Primis Protocol's rebasing token - PRM
 */
contract PrmToken is IPrmToken, ERC20Upgradeable, AccessControlUpgradeable {
    address public treasury;
    address public admin;
    address public PrimisBond;

    uint256 public refractionFeePercentage;
    uint256 public refractionFeeTotal;

    uint256 public prevAmount;
    uint256 public todayAmount;
    uint256 private lastTransfer;
    uint256 public lastEpoch;
    uint256 public mintPrec;
    uint256 public currentMintCount;
    uint lastYear;
    uint256 public mintFee;
    uint256 public mintCount;

    struct VestAmount {
        uint256 totalAmount;
        bool nineMonths;
        bool twelveMonths;
        bool fifteenMonths;
    }

    // minter role hash
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PrimisBOND_ROLE = keccak256("PrimisBOND_ROLE");

    mapping(address => bool) public excludeWallets;
    mapping(uint256 => uint256) public vestedAmounts; // count => amount
    mapping(uint256 => uint256) public vestedTime; // count => time
    mapping(uint256 => VestAmount) public yearlyVestAmount;

    event TreasuryContractChanged(address indexed newTreasury);
    event FeeUpdated(uint256 fee);
    event DayfeeUpdated(uint256 amount, uint256 updateTime);
    event RefractionFeesDistributed(address indexed to, uint256 indexed amount);
    event MintAndVest(uint256 time, uint256 mintAmount);
    event GetMintedPrm(uint256 time, uint256 withdrawAmount);

    /**
     * @notice Initializes the PrmToken contract
     */
    function initialize() external initializer {
        __ERC20_init("Prm Token", "PRM");
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        admin = msg.sender;
        excludeWallets[address(this)] = true;
        excludeWallets[msg.sender] = true;
        mintCount = 4;
        setFee(500);
        unchecked {
            lastTransfer = block.timestamp - (block.timestamp % 1 days);
        }

        // this is only for testing
        _mint(msg.sender, 1e13);
    }

    /**
     * @notice Returns the number of decimals
     * @return uint8 The number of decimal places the token uses
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function setBond(address addrs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (addrs == address(0)) revert ZeroAddress();
        PrimisBond = addrs;
        _grantRole(PrimisBOND_ROLE, addrs);
    }

    function setFee(uint256 fee) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee == 0) revert InvalidParam();
        refractionFeePercentage = fee;
        emit FeeUpdated(fee);
    }

    function setExclude(address[] calldata addrs, bool flag) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (addrs.length == 0) revert InvalidParam();
        unchecked {
            for (uint8 i; i < addrs.length; ++i) excludeWallets[addrs[i]] = flag;
        }
    }

    /**
     * @notice Sets the treasury contract address
     * @param treasury_ The new treasury contract address
     */
    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryContractChanged(treasury_);
    }

    function setAdmin(address _admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    function mintAndVest() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 time = block.timestamp;
        if ((lastYear * 31536000) + 365 days < time) revert WaitingTimeNotCompleted();
        uint256 mintAmount = (totalSupply() * mintFee) / 10000;
        yearlyVestAmount[time / 31536000] = VestAmount(mintAmount, false, false, false);
        mint(address(this), mintAmount);

        if (mintFee != 100) {
            mintFee -= 10;
        }
        if (lastYear == 0) lastYear = time / 31536000;
        emit MintAndVest(block.timestamp, mintAmount);
    }

    function getMintedPrm() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 time = block.timestamp;
        uint256 withdrawAmount = 0;
        uint256 secondsInYear = 31536000;
        uint256 lastYearStart = lastYear * secondsInYear;

        VestAmount memory lastYearVest = yearlyVestAmount[lastYear];

        if (lastYear < time / secondsInYear) {
            uint256 nineMonths = lastYearStart + 270 days;
            uint256 twelveMonths = lastYearStart + 360 days;
            uint256 fifteenMonths = lastYearStart + 450 days;

            if (!lastYearVest.nineMonths && nineMonths < time) withdrawAmount += lastYearVest.totalAmount / 3;
            if (!lastYearVest.twelveMonths && twelveMonths < time) withdrawAmount += lastYearVest.totalAmount / 3;
            if (!lastYearVest.fifteenMonths && fifteenMonths < time)
                withdrawAmount += (lastYearVest.totalAmount - (2 * lastYearVest.totalAmount) / 3);
        }

        uint256 currentYearStart = (time / secondsInYear) * secondsInYear;
        VestAmount memory currentYearVest = yearlyVestAmount[time / secondsInYear];

        if (!currentYearVest.nineMonths && currentYearStart + 270 days < time)
            withdrawAmount += currentYearVest.totalAmount / 3;
        if (!currentYearVest.twelveMonths && currentYearStart + 360 days < time)
            withdrawAmount += currentYearVest.totalAmount / 3;

        if (lastYear != time / secondsInYear) {
            lastYear = time / secondsInYear;
        }

        if (withdrawAmount > 0) {
            transfer(msg.sender, withdrawAmount);
        }
    }

    /**
     * @notice Mints a specified amount of tokens to the treasury
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (excludeWallets[from] || excludeWallets[to]) {
            super._transfer(from, to, amount);
        } else {
            uint256 fee = (amount * refractionFeePercentage) / 100;
            if (fee != 0) {
                unchecked {
                    refractionFeeTotal += fee;
                }
                super._transfer(from, address(this), fee);
            }
            super._transfer(from, to, amount - fee);
        }
    }

    function distributeRefractionFees() external onlyRole(PrimisBOND_ROLE) {
        uint256 feesToTransfer = refractionFeeTotal;
        if (feesToTransfer != 0) {
            refractionFeeTotal = 0;
            lastEpoch = block.timestamp;
            if (feesToTransfer != 0) {
                _approve(address(this), PrimisBond, feesToTransfer);
                IPrimisBond(PrimisBond).epochRewardShareIndex(feesToTransfer);
                emit RefractionFeesDistributed(PrimisBond, feesToTransfer);
            }
        }
    }
}
