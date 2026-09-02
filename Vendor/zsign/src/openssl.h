#pragma once
#include "json.h"

class ZSignAsset
{
public:
	ZSignAsset();
	// Init 把 EVP_PKEY/X509/CA 栈存入成员且全库无任何释放路径：CLI 短命进程无感，
	// 嵌入常驻 App 后每次签名泄漏一份私钥+证书+CA 栈（明文私钥材料滞留堆中）。
	~ZSignAsset();

public:
	// PKCS12 解析所需 provider 的进程级一次性加载（default 必需，legacy 尽力而为：
	// 静态构建可能未编入，加载失败即清错误队列防污染后续诊断）。旧实现每次
	// p12 解析都 OSSL_PROVIDER_load 一次且从不 unload，provider 引用计数持续累积。
	static void EnsurePKCS12ProvidersLoaded();

public:
	bool Init(const string& strCertFile,
				const string& strPKeyFile,
				const string& strProvFile,
				const string& strEntitleFile,
				const string& strPassword,
				bool bAdhoc,
				bool bSHA256Only,
				bool bSingleBinary);

	bool GenerateCMS(const string& strCDHashData, 
						const string& strCDHashesPlist, 
						const string& strCodeDirectorySlotSHA1, 
						const string& strAltnateCodeDirectorySlot256, 
						string& strCMSOutput);

private:
	bool GenerateCMS(void* pscert, 
						void* pspkey, 
						const string& strCDHashData, 
						const string& strCDHashesPlist, 
						const string& strCodeDirectorySlotSHA1, 
						const string& strAltnateCodeDirectorySlot256, 
						string& strCMSOutput);

	bool GetCertSubjectCN(void* cert, string& strSubjectCN);
	bool GetCertSubjectCN(const string& strCertData, string& strSubjectCN);

public:
	static bool		CMSError();
	// Returns the embedded WWDR intermediate (G1-G8) whose subject name hash
	// matches uIssuerHash, or NULL. Shared by signing and certificate check.
	static const char*	WWDRIntermediatePEM(unsigned long uIssuerHash);
	static void*	GenerateASN1Type(const string& value);
	static bool		GetCertInfo(void* pcert, jvalue& jvCertInfo);
	static bool		GetCMSInfo(uint8_t* pCMSData, uint32_t uCMSLength, jvalue& jvOutput);
	static bool		GetCMSContent(const string& strCMSDataInput, string& strContentOutput);
	static void		ParseCertSubject(const string& strSubject, jvalue& jvSubject);
	static string	ASN1_TIMEtoString(const void* time);

public:
	bool	m_bAdhoc;
	bool	m_bSHA256Only;
	bool	m_bSingleBinary;
	string	m_strTeamId;
	string	m_strSubjectCN;
	string	m_strProvData;
	string	m_strEntitleData;
	string	m_strApplicationId;

private:
	void*	m_evpPKey;
	void*	m_x509Cert;
	void*	m_caCerts; // STACK_OF(X509)* CA chain recovered from the input p12, if any

public:
	static const char* s_szAppleDevCACert;
	static const char* s_szAppleRootCACert;
	static const char* s_szAppleRootCACertG3;
	static const char* s_szAppleDevCACertG3;
	static const char* s_szAppleDevCACertG2;
	static const char* s_szAppleDevCACertG4;
	static const char* s_szAppleDevCACertG5;
	static const char* s_szAppleDevCACertG6;
	static const char* s_szAppleDevCACertG7;
	static const char* s_szAppleDevCACertG8;

public:
	class OpenSSLInit
	{
	public:
		OpenSSLInit();
	};
	static OpenSSLInit s_OpenSSLInit;
};
