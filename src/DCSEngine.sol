//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title DSCEngine
 * @author Nwaugo Walter
 *
 * The system is designed to be as minimal as possible, and to have the tokens maintain a peg to the USD. The system is designed to be governed by a separate contract, DCSEngine, which will be responsible for the minting and burning of tokens.
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by ETH and BTC.
 * @notice This contract is the core of the DCS system. It handles all the logic for mining and redeeming DSC, as well ad depositing and withdrawing collateral.
 * @notice This contrat is loosely based on  the MAKERDAO DSS (DAI system).
 */
import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DSCEngine is ReentrancyGuard {
    /////////////////////
    /// ERRORS
    /////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedTokens();
    error DSCEngine__DepositCollateralFailed();

    /////////////////////
    /// STATE VARIABLES
    /////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenAddress => priceFeedAddress
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    address weth;
    address wbtc;


    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////
    /// EVENTS
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /////////////////////
    /// MODIFIERS
    /////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        // if token isn't allowed, revert
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedTokens();
        }
        _;
    }

    /////////////////////
    /// FUNCTIONS //////
    /////////////////////
    constructor(address[] memory tokenAdresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD price feed
        if (tokenAdresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAdresses.length; i++) {
            s_priceFeeds[tokenAdresses[i]] = priceFeedAddresses[i];
            s_collateraTokens.push(tokenAdresses[i])
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////
    /// External FUNCTIONS
    /////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral  The amount of collateral to deposit
     * @notice This function allows users to deposit collateral into the system. The collateral will be used to back the minted DSC tokens.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__DepositCollateralFailed();
        }
    }

    /**
     *@notice follows CEI
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function allows the DCSEngine to mint DSC tokens. The DSC tokens are minted against the collateral deposited by users.
     * @notice must have more collateral than the amount of DSC to mint
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DCS, $100 ETH)
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function getcollateralValueInUsd(address user) external view returns (uint256) {
        uint256 totalCollateralValue = 0;
        for (uint256 i = 0; i < s_priceFeeds.length; i++) {
            totalCollateralValue += s_collateralDeposited[user][s_priceFeeds[i]];
        }
        return totalCollateralValue;
    }


    /////////////////////
    /// Private and INternal fuinctions 
    /////////////////////

    function  _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        uint256 totalDscMinted = s_dscMinted[user];
        uint256 collateralValueInUsd = getcollateralValueInUsd(user);
        for (uint256 i = 0; i < s_priceFeeds.length; i++) {
            collateralValueInUsd += s_collateralDeposited[user][s_priceFeeds[i]];
        }
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     * 
     * @param user The address of the user to check the health factor of
     * @notice Returns how close to liquidation a user is
     * 
     */
    function  _healthfactor(address user) private view returns (uint256) {
        // check health fator( do they have enought health factor
        // health factor = total collateral value / total DSC value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    }

    function _revertIfHealthFcatorIsBroken(address user) internal view {
        // check health fator( do they have enought health factor
        // health factor = total collateral value / total DSC value
        uint256 totalCollateralValue = 0;
        for (uint256 i = 0; i < s_priceFeeds.length; i++) {
            totalCollateralValue += s_collateralDeposited[user][s_priceFeeds[i]];
        }
        uint256 totalDscValue = s_dscMinted[user];
        if (totalCollateralValue < totalDscValue) {
            revert DSCEngine__HealthFactorBroken();
        }
    }


    /////////////////////
    /// Public and External view fuinctions 
    /////////////////////

    function getcollateralValueInUsd(address user) public view returns (uint256) {
        uint256 totalCollateralValue = 0;
        // loop through each collateral token and get the amount they have deposited and map it to price feed
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += s_collateralDeposited[user][s_priceFeeds[i]];
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token) public view returns (uint256) {
        
    }



}
