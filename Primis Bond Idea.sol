// SPDX-License-Identifier:To incorporate refraction fees, trading fees, rebasing fees, and the refraction index into the `PrimisBond` contract, we'll need to ensure that the contract can interact properly with the `PrmToken` contract to handle these functionalities.

### Updated PrimisBond Contract

Here's an updated version of the `PrimisBond` contract that includes the required functionalities:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Openzeppelin
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@chainlink/contracts/src/v0.8/automation/KeeperCompatible.sol";

// Interfaces
import "./interfaces/IBondNFT.sol";
import "./interfaces/IPrimisTreasury.sol";
import "./interfaces/IPrimisOracle.sol";
import "./interfaces/ISPrmToken.sol";
import "./interfaces/IPrmToken.sol";
import "./interfaces/IPrimisStaking.sol";
import "./PrmToken.sol";
import "./prmETHToken.sol";

contract PrimisBond is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, EIP712Upgradeable, KeeperCompatibleInterface {
    PrmToken public prmToken;
    prmETHToken public prmETHToken;
    IBondNFT public bondNFT;

    struct Bond {
        bool withdrawn;
        uint256 principal;
        uint256 startTime;
        uint256 maturity;
        address token;
        uint256 bondFee;
        uint256 refractionIndex;
    }

    mapping(uint256 => Bond) public bonds;

    event Deposit(address indexed sender, uint256 indexed tokenId, uint256 principal, uint256 maturity, address token);
    event Withdrawal(address indexed sender, uint256 indexed tokenId);
    event RefractionFeesDistributed(uint256 indexed amount);

    function initialize(address prmTokenAddress, address prmETHTokenAddress, address bondNFTAddress) public initializer {
        __Ownable_init();
        __EIP712_init("PrimisBond", "1");
        prmToken = PrmToken(prmTokenAddress);
        prmETHToken = prmETHToken(prmETHTokenAddress);
        bondNFT = IBondNFT(bondNFTAddress);
    }

    function deposit(uint256 principal, uint256 maturity, uint256 bondFee, address token) external payable nonReentrant returns (uint256 tokenId) {
        require(principal > 0, "Invalid principal amount");
        require(maturity >= 7 && maturity <= 365, "Invalid maturity period");
        require(bondFee >= 0 && bondFee <= 100, "Invalid bond fee");

        if (token == address(0)) {
            require(msg.value == principal, "Incorrect ETH amount sent");
        } else {
            require(IERC20(token).transferFrom(msg.sender, address(this), principal), "Token transfer failed");
        }

        prmETHToken.mint(msg.sender, principal);

        tokenId = bondNFT.mint(msg.sender);

        uint256 refractionIndex = calculateRefractionIndex(maturity);

        bonds[tokenId] = Bond({
            withdrawn: false,
            principal: principal,
            startTime: block.timestamp,
            maturity: maturity,
            token: token,
            bondFee: bondFee,
            refractionIndex: refractionIndex
        });

        emit Deposit(msg.sender, tokenId, principal, maturity, token);
    }

    function withdraw(uint256 tokenId) external nonReentrant {
        Bond storage bond = bonds[tokenId];
        require(!bond.withdrawn, "Bond already withdrawn");
        require(bondNFT.ownerOf(tokenId) == msg.sender, "Not bond owner");
        require(block.timestamp >= bond.startTime + (bond.maturity * 1 days), "Bond not matured");

        bond.withdrawn = true;
        prmETHToken.burn(msg.sender, bond.principal);

        uint256 yield = calculateYield(bond.principal, bond.maturity);
        prmToken.mint(msg.sender, yield);

        emit Withdrawal(msg.sender, tokenId);
    }

    function calculateYield(uint256 principal, uint256 maturity) internal view returns (uint256) {
        uint256 rate = getInterestRate(maturity);
        return (principal * rate) / 100;
    }

    function getInterestRate(uint256 maturity) public pure returns (uint256) {
        if (maturity >= 360) return 15;
        if (maturity >= 320) return 14;
        if (maturity >= 280) return 13;
        if (maturity >= 240) return 12;
        if (maturity >= 200) return 11;
        if (maturity >= 160) return 10;
        if (maturity >= 120) return 9;
        if (maturity >= 80) return 8;
        if (maturity >= 40) return 7;
        return 6;
    }

    function calculateRefractionIndex(uint256 maturity) internal pure returns (uint256) {
        if (maturity >= 360) return 46;
        if (maturity >= 180) return 28;
        if (maturity >= 90) return 19;
        if (maturity >= 60) return 16;
        if (maturity >= 30) return 13;
        if (maturity >= 20) return 12;
        if (maturity >= 15) return 11.5;
        if (maturity >= 10) return 11;
        if (maturity >= 5) return 10.5;
        return 10;
    }

    function distributeRefractionFees() external {
        uint256 totalFees = prmToken.refractionFeeTotal();
        require(totalFees > 0, "No fees to distribute");

        prmToken.distributeRefractionFees();

        emit RefractionFeesDistributed(totalFees);
    }
}
