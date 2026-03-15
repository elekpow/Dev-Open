# Install Samba Domain Controller

```
chmod +x ScriptInstallSamba.sh
./ScriptInstallSamba.sh
```

# Config Samba Domain Controller

*В переменных прописать необходимвые параметры домена

```
DOMAIN="test.local"           # Имя домена в нижнем регистре для DNS
REALM="TEST.LOCAL"            # Realm для Kerberos 
HOSTNAME=$(hostname -s)       # Имя хоста
FQDN="$HOSTNAME.$DOMAIN"      # FQDN доменное имя
NETBIOS_NAME="TEST"           # NetBIOS имя домена
ADMIN_PASS="Pas1234Pas10Kd"  # Пароль
SERVER_IP="192.168.10.10"     # IP адрес сервера
```


```
chmod +x ScriptConfig.sh
./ScriptConfig.sh
```

# Remove  Samba Domain Controller

```
chmod +x ServiceRemove.sh
./ServiceRemove.sh
```
