pragma solidity 0.4.24;

import "@aragon/templates-shared/contracts/BaseTemplate.sol";
import "@aragon/os/contracts/common/Uint256Helpers.sol";


contract CompanyTemplate is BaseTemplate {
    using Uint256Helpers for uint256;

    string constant private ERROR_MISSING_TOKEN_CACHE = "COMPANY_MISSING_TOKEN_CACHE";
    string constant private ERROR_EMPTY_HOLDERS = "COMPANY_EMPTY_HOLDERS";
    string constant private ERROR_BAD_HOLDERS_STAKES_LEN = "COMPANY_BAD_HOLDERS_STAKES_LEN";
    string constant private ERROR_BAD_VOTE_SETTINGS = "COMPANY_BAD_VOTE_SETTINGS";
    string constant private ERROR_BAD_PAYROLL_SETTINGS = "COMPANY_BAD_PAYROLL_SETTINGS";

    bool constant private TOKEN_TRANSFERABLE = true;
    uint8 constant private TOKEN_DECIMALS = uint8(18);
    uint256 constant private TOKEN_MAX_PER_ACCOUNT = uint256(0);            // no limit of tokens per account

    uint64 constant private DEFAULT_FINANCE_PERIOD = uint64(30 days);

    mapping (address => address) internal tokenCache;

    constructor(DAOFactory _daoFactory, ENS _ens, MiniMeTokenFactory _miniMeFactory, IFIFSResolvingRegistrar _aragonID)
        BaseTemplate(_daoFactory, _ens, _miniMeFactory, _aragonID)
        public
    {
        _ensureAragonIdIsValid(_aragonID);
        _ensureMiniMeFactoryIsValid(_miniMeFactory);
    }

    function newTokenAndInstance(
        string _tokenName,
        string _tokenSymbol,
        string _id,
        address[] _holders,
        uint256[] _stakes,
        uint64[3] _votingSettings, /* supportRequired, minAcceptanceQuorum, voteDuration */
        uint64 _financePeriod,
        bool _useAgentAsVault
    )
        external
    {
        newToken(_tokenName, _tokenSymbol);
        newInstance(_id, _holders, _stakes, _votingSettings, _financePeriod, _useAgentAsVault);
    }

    function newTokenAndInstance(
        string _tokenName,
        string _tokenSymbol,
        string _id,
        address[] _holders,
        uint256[] _stakes,
        uint64[3] _votingSettings, /* supportRequired, minAcceptanceQuorum, voteDuration */
        uint64 _financePeriod,
        bool _useAgentAsVault,
        uint256[3] _payrollSettings /* address denominationToken , IFeed priceFeed, uint64 rateExpiryTime */
    )
        external
    {
        newToken(_tokenName, _tokenSymbol);
        newInstance(_id, _holders, _stakes, _votingSettings, _financePeriod, _useAgentAsVault, _payrollSettings);
    }

    function newToken(string _name, string _symbol) public returns (MiniMeToken) {
        MiniMeToken token = _createToken(_name, _symbol, TOKEN_DECIMALS);
        _cacheToken(token, msg.sender);
        return token;
    }

    function newInstance(string _id, address[] _holders, uint256[] _stakes, uint64[3] _votingSettings, uint64 _financePeriod, bool _useAgentAsVault) public {
        _verifyCompanyParameters(_holders, _stakes, _votingSettings);
        (Kernel dao, ACL acl) = _createDAO();
        _setupApps(dao, acl, _holders, _stakes, _votingSettings, _financePeriod, _useAgentAsVault);
        _registerID(_id, dao);
    }

    function newInstance(
        string _id,
        address[] _holders,
        uint256[] _stakes,
        uint64[3] _votingSettings,
        uint64 _financePeriod,
        bool _useAgentAsVault,
        uint256[3] _payrollSettings /* address denominationToken , IFeed priceFeed, uint64 rateExpiryTime */
    )
        public
    {
        _verifyCompanyParameters(_holders, _stakes, _votingSettings);
        require(_payrollSettings.length == 3, ERROR_BAD_PAYROLL_SETTINGS);

        (Kernel dao, ACL acl) = _createDAO();
        (Finance finance, Voting voting) = _setupApps(dao, acl, _holders, _stakes, _votingSettings, _financePeriod, _useAgentAsVault);
        _setupPayrollApp(dao, acl, _payrollSettings, finance, voting);
        _registerID(_id, dao);
    }

    function _verifyCompanyParameters(address[] _holders, uint256[] _stakes, uint64[3] _votingSettings) internal {
        require(_holders.length > 0, ERROR_EMPTY_HOLDERS);
        require(_holders.length == _stakes.length, ERROR_BAD_HOLDERS_STAKES_LEN);
        require(_votingSettings.length == 3, ERROR_BAD_VOTE_SETTINGS);
    }

    function _setupApps(Kernel _dao, ACL _acl, address[] _holders, uint256[] _stakes, uint64[3] _votingSettings, uint64 _financePeriod, bool _useAgentAsVault) internal returns(Finance, Voting) {
        MiniMeToken token = _popTokenCache(msg.sender);
        Vault agentOrVault = _useAgentAsVault ? _installDefaultAgentApp(_dao) : _installVaultApp(_dao);
        Finance finance = _installFinanceApp(_dao, agentOrVault, _financePeriod == 0 ? DEFAULT_FINANCE_PERIOD : _financePeriod);
        TokenManager tokenManager = _installTokenManagerApp(_dao, token, TOKEN_TRANSFERABLE, TOKEN_MAX_PER_ACCOUNT);
        Voting voting = _installVotingApp(_dao, token, _votingSettings[0], _votingSettings[1], _votingSettings[2]);

        _mintTokens(_acl, tokenManager, _holders, _stakes);
        _setupPermissions(_dao, _acl, agentOrVault, voting, finance, tokenManager, _useAgentAsVault);

        return (finance, voting);
    }

    function _setupPayrollApp(Kernel _dao, ACL _acl, uint256[3] _payrollSettings, Finance _finance, Voting _voting) internal {
        address denominationToken = _toAddress(_payrollSettings[0]);
        IFeed priceFeed = IFeed(_toAddress(_payrollSettings[1]));
        uint64 rateExpiryTime = _payrollSettings[2].toUint64();

        Payroll payroll = _installPayrollApp(_dao, _finance, denominationToken, priceFeed, rateExpiryTime);
        _createPayrollPermissions(_acl, payroll, _voting, _voting);
    }

    function _setupPermissions(Kernel _dao, ACL _acl, Vault _agentOrVault, Voting _voting, Finance _finance, TokenManager _tokenManager, bool _useAgentAsVault) internal {
        if (_useAgentAsVault) {
            _createAgentPermissions(_acl, Agent(_agentOrVault), _voting, _voting);
        }
        _createVaultPermissions(_acl, _agentOrVault, _finance, _voting);
        _createFinancePermissions(_acl, _finance, _voting, _voting);
        _createEvmScriptsRegistryPermissions(_acl, _voting, _voting);
        _createCustomVotingPermissions(_acl, _voting, _tokenManager);
        _createCustomTokenManagerPermissions(_acl, _tokenManager, _voting);
        _transferRootPermissionsFromTemplate(_dao, _voting);
    }

    function _createCustomVotingPermissions(ACL _acl, Voting _voting, TokenManager _tokenManager) internal {
        _acl.createPermission(_tokenManager, _voting, _voting.CREATE_VOTES_ROLE(), _voting);
        _acl.createPermission(_voting, _voting, _voting.MODIFY_QUORUM_ROLE(), _voting);
        _acl.createPermission(_voting, _voting, _voting.MODIFY_SUPPORT_ROLE(), _voting);
    }

    function _createCustomTokenManagerPermissions(ACL _acl, TokenManager _tokenManager, Voting _voting) internal {
        _acl.createPermission(_voting, _tokenManager, _tokenManager.BURN_ROLE(), _voting);
        _acl.createPermission(_voting, _tokenManager, _tokenManager.MINT_ROLE(), _voting);
    }

    function _cacheToken(MiniMeToken _token, address _owner) internal {
        tokenCache[_owner] = _token;
    }

    function _popTokenCache(address _owner) internal returns (MiniMeToken) {
        require(tokenCache[_owner] != address(0), ERROR_MISSING_TOKEN_CACHE);

        MiniMeToken token = MiniMeToken(tokenCache[_owner]);
        delete tokenCache[_owner];
        return token;
    }
}
