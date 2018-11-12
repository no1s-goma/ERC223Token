pragma solidity ^0.4.18;

import "./Erc223TokenByGoma.sol";

/**
 * コイン交換用コントラクト
 */
contract CoinExchanger is Ownable {
    using SafeMath for uint256;

    Erc223TokenByGoma public mainCoin; // メインコイン
    Erc223TokenByGoma public subCoin;  // サブコイン
    uint256 public rate;               // 交換レート(ex. rate=10の場合、10subCoinで1mainCoin)

    /**
     * @dev コンストラクタ
     * 
     * @param _mainCoinAddress address メインコインのコントラクトアドレス
     * @param _subCoinAddress address サブコインのコントラクトアドレス
     * @param _rate uint256 コインの交換レート
     */
    function CoinExchanger(address _mainCoinAddress, address _subCoinAddress, uint256 _rate) public {
        require(_mainCoinAddress != 0x0);
        require(_subCoinAddress != 0x0);
        require(_rate > 0);
      
        mainCoin = Erc223TokenByGoma(_mainCoinAddress);
        subCoin  = Erc223TokenByGoma(_subCoinAddress);
        rate     = _rate;
    }

    /**
     * @dev コイン交換（main -> sub）
     * 
     * onlyOwner 管理者のみ実行可能
     * @param _user address コイン交換依頼者のアドレス
     * @param _amount uint256 交換トークン量(mainCoin)
     */
    function ExchangeFromMainToSub(address _user, uint256 _amount) onlyOwner public returns (bool) {
        require(_user != 0x0);
        require(_amount > 0);
        
        uint256 mainAmount = _amount;
        uint256 mainBalance = mainCoin.balanceOf(_user);
        uint256 subAmount = _amount.mul(rate);

        require (mainBalance >= mainAmount);
        
        mainCoin.burn(_user, mainAmount, msg.sender);
        subCoin.mint(_user, subAmount, msg.sender);
        
        return true;
    }

    /**
     * @dev コイン交換（sub -> main）
     * 
     * onlyOwner 管理者のみ実行可能
     * @param _user address コイン交換依頼者のアドレス
     * @param _amount uint256 交換トークン量(subCoin)
     */
    function ExchangeFromSubToMain(address _user, uint256 _amount) onlyOwner public returns (bool) {
        require(_user != 0x0);
        require(_amount > 0);
        
        uint256 mainAmount = _amount.div(rate);
        uint256 subAmount = _amount;
        uint256 subBalance = subCoin.balanceOf(_user);
        
        require (subBalance >= subAmount);

        mainCoin.mint(_user, mainAmount, msg.sender);
        subCoin.burn(_user, subAmount, msg.sender);

        return true;    
    }

    /**
     * @dev 交換レートの変更
     * 
     * onlyOwner 管理者のみ実行可能
     * @param _newRate uint256 変更後の交換レート
     */
    function ChangeRate(uint256 _newRate) onlyOwner public {
        require(_newRate > 0);
        rate = _newRate;
    }
}
