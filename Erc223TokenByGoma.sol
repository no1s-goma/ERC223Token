pragma solidity ^0.4.18;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./ContractReceiver.sol";

/**
 * @title ERC223抽象クラス
 */
contract ERC223 {
	function totalSupply() public constant returns (uint256);
	function balanceOf(address _owner) public constant returns (uint256);
	function transferFrom(address _from, address _to, uint256 _value) public returns (bool success);
	function approve(address _spender, uint256 _value) public returns (bool success);
	function allowance(address _owner, address _spender) public constant returns (uint256);
	function transfer(address _to, uint256 _value) public returns (bool success);
	function transfer(address _to, uint256 _value, bytes _data) public returns (bool success);
	function transfer(address _to, uint256 _value, bytes _data, string _custom_fallback) public returns (bool success);

	/* ERC223 Events */
	event Transfer(address indexed _from, address indexed _to, uint256 _value);
	event Approval(address indexed _owner, address indexed _spender, uint256 _value);
	event Transfer(address indexed _from, address indexed _to, uint256 _value, bytes _data);
}

/**
 * @title Erc223TokenByGoma
 * @dev ERC223規格のトークン。ERC20規格との互換性あり
 */
contract Erc223TokenByGoma is ERC223, Ownable {
    using SafeMath for uint256; // バリデーション付き四則演算をuint256で使用する

    string public name;                      // トークン名
    string public symbol;                    // トークンの通貨単位
    uint8 public decimals = 18;              // 小数点以下の数
    uint256 public totalSupply;              // 総供給量
    uint256 public distributeAmount = 0;     // 分配トークン量（デフォは0）
    bool public mintingFinished = false;     // minting終了フラグ

    // 自トークンを特定ユーザが送金できるようにする割り当てマッピング
    mapping(address => mapping (address => uint256)) public allowance;
    mapping(address => uint256) public balanceOf;       // 個別残高
    mapping (address => bool) public frozenAccount;     // 凍結アカウント true:凍結中|false:未凍結
    mapping (address => uint256) public unlockUnixTime; // ロックアップアカウント

    // 各種イベントを定義
    event FrozenFunds(address indexed target, bool frozen);
    event LockedFunds(address indexed target, uint256 locked);
    event Burn(address indexed from, uint256 amount);
    event Mint(address indexed to, uint256 amount);
    event MintFinished();
    event Transfer(address indexed from, address indexed to, uint value, bytes indexed data);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint _value);

    /**
     * コンストラクタ
     * オーナーの設定を行い、総供給量をオーナーの残高へ
     *
     * @param _name string トークン名
     * @param _symbol string トークンの通貨単位
     * @param _totalSupply uint256 トークンの総供給量
     */
    function Erc223TokenByGoma(string _name, string _symbol, uint256 _totalSupply) public {
        // トークン情報の設定
        name = _name;
        symbol = _symbol;
        totalSupply = _totalSupply.mul(1e18);

        // デプロイ実行者を管理者とする。
        owner = msg.sender;
        balanceOf[msg.sender] = totalSupply;
    }

    /*
     * Getter関数
     * 指定した変数の値を取得する
     */
    function name() public view returns (string _name) { return name; } // トークン名
    function symbol() public view returns (string _symbol) { return symbol; } // トークンの単位
    function decimals() public view returns (uint8 _decimals) { return decimals; } // 小数部分の桁数
    function totalSupply() public view returns (uint256 _totalSupply) { return totalSupply; } // 総供給量
    function balanceOf(address _owner) public view returns (uint256 balance) { return balanceOf[_owner]; } // 指定アドレスの所持トークン量

    /**
     * @dev 指定アドレスの凍結|凍結解除を行う
     *
     * onlyOwner 管理者のみ実行可
     * @param targets address[] 凍結したいアドレスの配列
     * @param isFrozen bool true:コイン凍結 false:凍結解除
     */
    function freezeAccounts(address[] targets, bool isFrozen) onlyOwner public {
        require(targets.length > 0);

        for (uint j = 0; j < targets.length; j++) {
            require(targets[j] != 0x0);
            frozenAccount[targets[j]] = isFrozen;
            FrozenFunds(targets[j], isFrozen);
        }
    }

    /**
     * @dev 指定アドレスのロックアップ（指定時間が来るまでトークン移動を実施できなくさせる）
     *
     * onlyOwner 管理者のみ実行可
     * @param targets address[] ロックアップ対象アドレス
     * @param unixTimes uint[] ロックアップ解除時間（unixタイム）
     */
    function lockupAccounts(address[] targets, uint[] unixTimes) onlyOwner public {
        require(targets.length > 0
                && targets.length == unixTimes.length);

        for(uint j = 0; j < targets.length; j++){
            require(unlockUnixTime[targets[j]] < unixTimes[j]);
            unlockUnixTime[targets[j]] = unixTimes[j];
            LockedFunds(targets[j], unixTimes[j]);
        }
    }

    /**
     * @dev ERC223規格の送金処理
     *
     * @param _to address 送金先アドレス|コントラクトアドレス
     * @param _value uint 送金量
     * @param _data bytes データ
     * @param _custom_fallback string カスタムフォールバック
     */
    function transfer(address _to, uint _value, bytes _data, string _custom_fallback) public returns (bool success) {
        require(_value > 0
                && frozenAccount[msg.sender] == false
                && frozenAccount[_to] == false
                && now > unlockUnixTime[msg.sender]
                && now > unlockUnixTime[_to]);

        if (isContract(_to)) {
            require(balanceOf[msg.sender] >= _value);
            balanceOf[msg.sender] = balanceOf[msg.sender].sub(_value);
            balanceOf[_to] = balanceOf[_to].add(_value);
            assert(_to.call.value(0)(bytes4(keccak256(_custom_fallback)), msg.sender, _value, _data));
            Transfer(msg.sender, _to, _value, _data);
            Transfer(msg.sender, _to, _value);
            return true;
        } else {
            return transferToAddress(_to, _value, _data);
        }
    }

    /**
     * @dev ERC223規格の送金処理2
     *
     * @param _to address 送金先アドレス|コントラクトアドレス
     * @param _value uint 送金量
     * @param _data bytes データ
     */
    function transfer(address _to, uint _value, bytes _data) public returns (bool success) {
        require(_value > 0
                && frozenAccount[msg.sender] == false
                && frozenAccount[_to] == false
                && now > unlockUnixTime[msg.sender]
                && now > unlockUnixTime[_to]);

        if (isContract(_to)) {
            return transferToContract(_to, _value, _data);
        } else {
            return transferToAddress(_to, _value, _data);
        }
    }

    /**
     * @dev ERC20規格の送金処理
     *      下位互換性を持つための実装。ERC20トークンとしても使用できる
     *
     * @param _to address 送金先アドレス|コントラクトアドレス
     * @param _value uint 送金量
     */
    function transfer(address _to, uint _value) public returns (bool success) {
        require(_value > 0
                && frozenAccount[msg.sender] == false
                && frozenAccount[_to] == false
                && now > unlockUnixTime[msg.sender]
                && now > unlockUnixTime[_to]);

        bytes memory empty;
        if (isContract(_to)) {
            return transferToContract(_to, _value, empty);
        } else {
            return transferToAddress(_to, _value, empty);
        }
    }

    /**
     * @dev コントラクトアドレスかどうかのチェック
     *
     * @param _addr address 送金先アドレス|コントラクトアドレス
     */

    function isContract(address _addr) private view returns (bool is_contract) {
        uint length;

        // アドレスサイズからコントラクトかどうかを判断
        assembly {
            //retrieve the size of the code on target address, this needs assembly
            length := extcodesize(_addr)
        }
        return (length > 0);
    }

    /**
     * @dev 送金対象がアドレスの時の送金処理
     *
     * @param _to address 送金先アドレス
     * @param _value uint 送金量
     * @param _data bytes データ
     */
    function transferToAddress(address _to, uint _value, bytes _data) private returns (bool success) {
        require(balanceOf[msg.sender] >= _value);
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(_value);
        balanceOf[_to] = balanceOf[_to].add(_value);
        Transfer(msg.sender, _to, _value, _data);
        Transfer(msg.sender, _to, _value);
        return true;
    }

    /**
     * @dev 送金対象がコントラクトの時の送金処理
     *
     * @param _to address コントラクトアドレス
     * @param _value uint 送金量
     * @param _data bytes データ
     */
    function transferToContract(address _to, uint _value, bytes _data) private returns (bool success) {
        require(balanceOf[msg.sender] >= _value);
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(_value);
        balanceOf[_to] = balanceOf[_to].add(_value);
        ContractReceiver receiver = ContractReceiver(_to);
        receiver.tokenFallback(msg.sender, _value, _data);
        Transfer(msg.sender, _to, _value, _data);
        Transfer(msg.sender, _to, _value);
        return true;
    }

    /**
     * @dev 他の指定アドレスから送金する処理（ERC20規格）
     *      下位互換性を持つために実装。ERC20トークンとしても使用できる
     *
     * 送金者のアカウントから受取人(_to)へトークン(_value)を送金する
     *
     * @param _from address 送金者のアドレス
     * @param _to address 受取人のアドレス
     * @param _value uint256 送金量
     */
    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        require(_to != address(0)
                && _value > 0
                && balanceOf[_from] >= _value
                && allowance[_from][msg.sender] >= _value
                && frozenAccount[_from] == false
                && frozenAccount[_to] == false
                && now > unlockUnixTime[_from]
                && now > unlockUnixTime[_to]);

        balanceOf[_from] = balanceOf[_from].sub(_value);
        balanceOf[_to] = balanceOf[_to].add(_value);
        allowance[_from][msg.sender] = allowance[_from][msg.sender].sub(_value);
        Transfer(_from, _to, _value);
        return true;
    }

    /**
     * @dev 他のアドレスに割り当てを行う（ERC20規格）
     *      下位互換性を持つために実装。ERC20トークンとしても使用できる
     *
     * 「_spender」に「_value」だけ自分のトークンを使用する許可をだす
     *
     * @param _spender address トークンの使用を認めるアドレス
     * @param _value uint256 「_spender」が使用することのできる最大額
     */
    function approve(address _spender, uint256 _value) public returns (bool success) {
        allowance[msg.sender][_spender] = _value;
        Approval(msg.sender, _spender, _value);
        return true;
    }

    /**
     * @dev 割当額の確認（ERC20規格）
     *      下位互換性を持つために実装。ERC20トークンとしても使用できる
     *
     * 「_spender」がどれだけ「_owner」のトークンを送金できる状態になっているか確認する
     *
     * @param _owner address 自分のアドレス
     * @param _spender address 割当先アドレス
     */
    function allowance(address _owner, address _spender) public view returns (uint256 remaining) {
        return allowance[_owner][_spender];
    }

    /**
     * @dev トークンの発行枚数を減らす機能
     *
     * onlyOwner 管理者のみ実行可
     * @param _from address burn対象アドレス
     * @param _unitAmount uint256 burnするトークン量
     */
    function burn(address _from, uint256 _unitAmount) onlyOwner public returns(bool) {
        require(_unitAmount > 0
                && balanceOf[_from] >= _unitAmount);

        balanceOf[_from] = balanceOf[_from].sub(_unitAmount);
        totalSupply = totalSupply.sub(_unitAmount);
        Burn(_from, _unitAmount);
        return true;
    }

    /**
     * @dev トークンの発行枚数を減らす機能（外部コントラクト用）
     *      別コントラクトから呼び出された場合、関数内でオーナーチェックを行う
     *
     * onlyOwner 管理者のみ実行可
     * @param _from address burn対象アドレス
     * @param _unitAmount uint256 burnするトークン量
     * @param _owner address 管理者アドレス
     */
    function burn(address _from, uint256 _unitAmount, address _owner) public returns(bool) {
        require(_unitAmount > 0
                && balanceOf[_from] >= _unitAmount);
        require(_owner == owner);

        balanceOf[_from] = balanceOf[_from].sub(_unitAmount);
        totalSupply = totalSupply.sub(_unitAmount);
        Burn(_from, _unitAmount);
        return true;
    }

    /**
     * minting可能かチェックする
     */
    modifier canMint() {
        require(!mintingFinished);
        _;
    }

    /**
     * @dev トークンの発行枚数を増やす機能
     *
     * onlyOwner 管理者のみ実行可
     * canMint このトークンがminting可能であること
     * @param _to address minting対象アドレス
     * @param _unitAmount uint256 mintingするトークン量
     */
    function mint(address _to, uint256 _unitAmount) onlyOwner canMint public returns (bool) {
        require(_unitAmount > 0);

        totalSupply = totalSupply.add(_unitAmount);
        balanceOf[_to] = balanceOf[_to].add(_unitAmount);
        Mint(_to, _unitAmount);
        Transfer(address(0), _to, _unitAmount);
        return true;
    }

    /**
     * @dev トークンの発行枚数を増やす機能（外部コントラクト用）
     *      別コントラクトから呼び出された場合、関数内でオーナーチェック
     *
     * onlyOwner 管理者のみ実行可
     * canMint このトークンがminting可能であること
     * @param _to address minting対象アドレス
     * @param _unitAmount uint256 mintingするトークン量
     * @param _owner address オーナーのアドレス
     */
    function mint(address _to, uint256 _unitAmount, address _owner) canMint public returns (bool) {
        require(_unitAmount > 0);
        require(_owner == owner);

        totalSupply = totalSupply.add(_unitAmount);
        balanceOf[_to] = balanceOf[_to].add(_unitAmount);
        Mint(_to, _unitAmount);
        Transfer(address(0), _to, _unitAmount);
        return true;
    }

    /**
     * @dev 二度とコインを新規発行できなくする
     *
     * onlyOwner 管理者のみ実行可
     * canMint このトークンがminting可能であること
     */
    function finishMinting() onlyOwner canMint public returns (bool) {
        mintingFinished = true;
        MintFinished();
        return true;
    }

    /**
     * @dev 指定アドレスに同額のコインを配布するAirDrop機能
     *      少ない送金手数料で沢山のアドレスへ一括送付できる
     *
     * @param addresses address[] 送金先アドレス
     * @param amount uint256 送金量
     */
    function distributeAirdrop(address[] addresses, uint256 amount) public returns (bool) {
        require(amount > 0
                && addresses.length > 0
                && frozenAccount[msg.sender] == false
                && now > unlockUnixTime[msg.sender]);

        amount = amount.mul(1e18);
        uint256 totalAmount = amount.mul(addresses.length);
        require(balanceOf[msg.sender] >= totalAmount);

        for (uint j = 0; j < addresses.length; j++) {
            require(addresses[j] != 0x0
                    && frozenAccount[addresses[j]] == false
                    && now > unlockUnixTime[addresses[j]]);

            balanceOf[addresses[j]] = balanceOf[addresses[j]].add(amount);
            Transfer(msg.sender, addresses[j], amount);
        }
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(totalAmount);
        return true;
    }

    /**
     * @dev 指定アドレスに指定額のコインを配布するAirDrop機能
     *      少ない送金手数料で沢山のアドレスへ一括送付できる
     *      address配列とamounts配列の要素数が同じであること
     *
     * @param addresses address[] 送金先アドレス
     * @param amounts uint[] 送金量
     */
    function distributeAirdrop2(address[] addresses, uint[] amounts) public returns (bool) {
        require(addresses.length > 0
                && addresses.length == amounts.length
                && frozenAccount[msg.sender] == false
                && now > unlockUnixTime[msg.sender]);

        uint256 totalAmount = 0;

        for(uint j = 0; j < addresses.length; j++){
            require(amounts[j] > 0
                    && addresses[j] != 0x0
                    && frozenAccount[addresses[j]] == false
                    && now > unlockUnixTime[addresses[j]]);

            amounts[j] = amounts[j].mul(1e18);
            totalAmount = totalAmount.add(amounts[j]);
        }
        require(balanceOf[msg.sender] >= totalAmount);

        for (j = 0; j < addresses.length; j++) {
            balanceOf[addresses[j]] = balanceOf[addresses[j]].add(amounts[j]);
            Transfer(msg.sender, addresses[j], amounts[j]);
        }
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(totalAmount);
        return true;
    }

    /**
     * @dev 特定アドレスからトークンを徴収する機能
     *
     * onlyOwner 管理者のみ実行可
     * @param addresses address[] 徴収対象のアドレスリスト
     * @param amounts uint[] 徴収量
     */
    function collectTokens(address[] addresses, uint[] amounts) onlyOwner public returns (bool) {
        require(addresses.length > 0
                && addresses.length == amounts.length);

        uint256 totalAmount = 0;

        for (uint j = 0; j < addresses.length; j++) {
            require(amounts[j] > 0
                    && addresses[j] != 0x0
                    && frozenAccount[addresses[j]] == false
                    && now > unlockUnixTime[addresses[j]]);

            amounts[j] = amounts[j].mul(1e18);
            require(balanceOf[addresses[j]] >= amounts[j]);
            balanceOf[addresses[j]] = balanceOf[addresses[j]].sub(amounts[j]);
            totalAmount = totalAmount.add(amounts[j]);
            Transfer(addresses[j], msg.sender, amounts[j]);
        }
        balanceOf[msg.sender] = balanceOf[msg.sender].add(totalAmount);
        return true;
    }

    /**
     * @dev distributeAmountのセット
     *
     * onlyOwner 管理者のみ実行可
     * @param _unitAmount uint256 distributeAmount
     */
    function setDistributeAmount(uint256 _unitAmount) onlyOwner public {
        distributeAmount = _unitAmount;
    }

    /**
     * @dev 他の人がガスを消費して運営者のアドレスからトークンを手に入れる機能
     *      もしdistributeAmountが0設定なら、この関数は動かない
     */
    function autoDistribute() payable public {
        require(distributeAmount > 0
                && balanceOf[owner] >= distributeAmount
                && frozenAccount[msg.sender] == false
                && now > unlockUnixTime[msg.sender]);
        if(msg.value > 0) owner.transfer(msg.value);

        balanceOf[owner] = balanceOf[owner].sub(distributeAmount);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(distributeAmount);
        Transfer(owner, msg.sender, distributeAmount);
    }

    /**
     * @dev fallback function
     */
    function() payable public {
        autoDistribute();
    }
}
