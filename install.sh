#!/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check OS (Ubuntu/Debian)
if ! grep -E 'Ubuntu|Debian' /etc/os-release > /dev/null; then
    echo "This script only supports Ubuntu or Debian"
    exit 1
fi

# Update system
apt-get update && apt-get upgrade -y || { echo "Failed to update system"; exit 1; }

# Install required dependencies with error checking
apt-get install -y strongswan xl2tpd iptables php php-fpm php-mysql php-mbstring php-xml php-zip composer nginx mysql-server || { echo "Failed to install dependencies"; exit 1; }

# Ensure PHP and MySQL commands are available
if ! command -v php >/dev/null 2>&1; then
    echo "PHP not found, reinstalling..."
    apt-get install -y php php-fpm
fi
if ! command -v mysql >/dev/null 2>&1; then
    echo "MySQL not found, reinstalling..."
    apt-get install -y mysql-server
fi

# Install L2TP/IPsec
echo "Configuring L2TP/IPsec..."
cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"
conn %default
    ikelifetime=60m
    keylife=20m
    rekeymargin=3m
    keyingtries=1
conn L2TP-PSK
    authby=secret
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/1701
    auto=add
EOF

cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
[lns default]
ip range = 192.168.1.100-192.168.1.200
local ip = 192.168.1.1
require chap = yes
refuse pap = yes
require authentication = yes
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
asyncmap 0
auth
crtscts
lock
hide-password
modem
debug
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF

# Setup PSK
read -p "Enter Pre-Shared Key (PSK): " psk
cat > /etc/ipsec.secrets <<EOF
%any %any : PSK "$psk"
EOF

# Setup initial user
read -p "Enter VPN username: " vpn_user
read -p "Enter VPN password: " vpn_pass
cat > /etc/ppp/chap-secrets <<EOF
$vpn_user l2tpd $vpn_pass *
EOF

# Configure firewall
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "Warning: iptables NAT setup failed"
iptables -A FORWARD -p udp --dport 1701 -j ACCEPT
iptables -A FORWARD -p udp --dport 500 -j ACCEPT
iptables -A FORWARD -p udp --dport 4500 -j ACCEPT
apt-get install -y iptables-persistent || echo "Warning: iptables-persistent not installed"
service netfilter-persistent start || echo "Warning: netfilter-persistent failed to start"

# Start and enable services with error checking
systemctl enable ipsec || echo "Warning: Failed to enable strongswan"
systemctl restart ipsec || echo "Warning: Failed to restart strongswan"
systemctl enable xl2tpd || echo "Warning: Failed to enable xl2tpd"
systemctl restart xl2tpd || echo "Warning: Failed to restart xl2tpd"

# Create Laravel directory if it doesn't exist
mkdir -p /var/www/vpn_panel
chown -R www-data:www-data /var/www/vpn_panel
chmod -R 775 /var/www/vpn_panel/storage
chmod -R 775 /var/www/vpn_panel/bootstrap/cache

# Install Laravel
cd /var/www/vpn_panel
composer create-project --prefer-dist laravel/laravel . || { echo "Failed to install Laravel"; exit 1; }

# Setup MySQL
mysql -u root -e "CREATE DATABASE IF NOT EXISTS vpn_panel;" || { echo "Failed to create database"; exit 1; }
mysql -u root -e "CREATE USER IF NOT EXISTS 'vpn_admin'@'localhost' IDENTIFIED BY 'secure_password';" || { echo "Failed to create MySQL user"; exit 1; }
mysql -u root -e "GRANT ALL PRIVILEGES ON vpn_panel.* TO 'vpn_admin'@'localhost';" || { echo "Failed to grant privileges"; exit 1; }
mysql -u root -e "FLUSH PRIVILEGES;" || { echo "Failed to flush privileges"; exit 1; }

# Configure Laravel .env
cat > /var/www/vpn_panel/.env <<EOF
APP_NAME=VPN_Panel
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=http://localhost

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=vpn_panel
DB_USERNAME=vpn_admin
DB_PASSWORD=secure_password
EOF

# Generate Laravel key
php artisan key:generate || { echo "Failed to generate Laravel key"; exit 1; }

# Create Laravel project files
mkdir -p /var/www/vpn_panel/database/migrations
mkdir -p /var/www/vpn_panel/app/Models
mkdir -p /var/www/vpn_panel/app/Http/Controllers
mkdir -p /var/www/vpn_panel/resources/views/layouts

# Migration: vpn_users
cat > /var/www/vpn_panel/database/migrations/2025_06_29_000001_create_vpn_users_table.php <<EOF
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

class CreateVpnUsersTable extends Migration
{
    public function up()
    {
        Schema::create('vpn_users', function (Blueprint \$table) {
            \$table->id();
            \$table->string('username')->unique();
            \$table->string('password');
            \$table->timestamp('created_at')->useCurrent();
            \$table->timestamp('expires_at')->nullable();
            \$table->integer('connection_limit')->default(0);
            \$table->integer('connections_used')->default(0);
        });
    }

    public function down()
    {
        Schema::dropIfExists('vpn_users');
    }
}
EOF

# Migration: admins
cat > /var/www/vpn_panel/database/migrations/2025_06_29_000002_create_admins_table.php <<EOF
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Hash;

class CreateAdminsTable extends Migration
{
    public function up()
    {
        Schema::create('admins', function (Blueprint \$table) {
            \$table->id();
            \$table->string('username')->unique();
            \$table->string('password');
            \$table->timestamps();
        });

        DB::table('admins')->insert([
            'username' => 'admin',
            'password' => Hash::make('admin123'),
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }

    public function down()
    {
        Schema::dropIfExists('admins');
    }
}
EOF

# Model: VpnUser
cat > /var/www/vpn_panel/app/Models/VpnUser.php <<EOF
<?php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class VpnUser extends Model
{
    protected \$fillable = ['username', 'password', 'expires_at', 'connection_limit', 'connections_used'];

    public function syncToChapSecrets()
    {
        \$lines = [];
        \$users = self::all();
        foreach (\$users as \$user) {
            \$lines[] = "\{\$user->username} l2tpd {\$user->password} *";
        }
        file_put_contents('/etc/ppp/chap-secrets', implode("\n", \$lines) . "\n");
        shell_exec('systemctl restart xl2tpd');
    }
}
EOF

# Model: Admin
cat > /var/www/vpn_panel/app/Models/Admin.php <<EOF
<?php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Hash;

class Admin extends Model
{
    protected \$fillable = ['username', 'password'];

    public function setPasswordAttribute(\$value)
    {
        \$this->attributes['password'] = Hash::make(\$value);
    }
}
EOF

# Controller: VpnController
cat > /var/www/vpn_panel/app/Http/Controllers/VpnController.php <<EOF
<?php
namespace App\Http\Controllers;

use App\Models\VpnUser;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Log;

class VpnController extends Controller
{
    public function __construct()
    {
        \$this->middleware('auth:admin')->except(['login', 'loginPost']);
    }

    public function dashboard()
    {
        \$userCount = VpnUser::count();
        \$activeUsers = 0; // Implement actual logic using ipsec status
        \$strongswanStatus = shell_exec('systemctl is-active strongswan');
        \$xl2tpdStatus = shell_exec('systemctl is-active xl2tpd');

        return view('dashboard', compact('userCount', 'activeUsers', 'strongswanStatus', 'xl2tpdStatus'));
    }

    public function users()
    {
        \$users = VpnUser::all();
        return view('users', compact('users'));
    }

    public function addUser(Request \$request)
    {
        \$request->validate([
            'username' => 'required|unique:vpn_users',
            'password' => 'required',
            'expires_at' => 'nullable|date',
            'connection_limit' => 'nullable|integer',
        ]);

        \$user = VpnUser::create(\$request->all());
        \$user->syncToChapSecrets();

        return redirect()->route('users')->with('success', 'User added successfully');
    }

    public function editUser(Request \$request, VpnUser \$user)
    {
        \$request->validate([
            'password' => 'required',
            'expires_at' => 'nullable|date',
            'connection_limit' => 'nullable|integer',
        ]);

        \$user->update(\$request->all());
        \$user->syncToChapSecrets();

        return redirect()->route('users')->with('success', 'User updated successfully');
    }

    public function deleteUser(VpnUser \$user)
    {
        \$user->delete();
        \$user->syncToChapSecrets();

        return redirect()->route('users')->with('success', 'User deleted successfully');
    }

    public function logs()
    {
        \$logs = [];
        if (file_exists('/var/log/xl2tpd.log')) {
            \$logs = array_slice(file('/var/log/xl2tpd.log'), -50);
        }
        return view('logs', compact('logs'));
    }

    public function login()
    {
        return view('login');
    }

    public function loginPost(Request \$request)
    {
        \$credentials = \$request->validate([
            'username' => 'required',
            'password' => 'required',
        ]);

        if (Auth::guard('admin')->attempt(\$credentials)) {
            return redirect()->route('dashboard');
        }

        return back()->withErrors(['username' => 'Invalid credentials']);
    }

    public function logout()
    {
        Auth::guard('admin')->logout();
        return redirect()->route('login');
    }
}
EOF

# Layout: app.blade.php
cat > /var/www/vpn_panel/resources/views/layouts/app.blade.php <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPN Panel</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
</head>
<body class="bg-gray-100">
    <div class="container mx-auto p-4">
        @if (Auth::guard('admin')->check())
        <nav class="bg-blue-600 text-white p-4 rounded mb-4 flex justify-between">
            <h1 class="text-2xl font-bold">VPN Admin Panel</h1>
            <a href="{{ route('logout') }}" class="text-white hover:underline">Logout</a>
        </nav>
        @endif
        @yield('content')
    </div>
</body>
</html>
EOF

# View: dashboard.blade.php
cat > /var/www/vpn_panel/resources/views/dashboard.blade.php <<EOF
@extends('layouts.app')

@section('content')
<div class="grid grid-cols-1 md:grid-cols-3 gap-4">
    <div class="bg-white p-4 rounded shadow">
        <h2 class="text-lg font-semibold">Total Users</h2>
        <p class="text-2xl">{{ \$userCount }}</p>
    </div>
    <div class="bg-white p-4 rounded shadow">
        <h2 class="text-lg font-semibold">Active Users</h2>
        <p class="text-2xl">{{ \$activeUsers }}</p>
    </div>
    <div class="bg-white p-4 rounded shadow">
        <h2 class="text-lg font-semibold">Service Status</h2>
        <p>StrongSwan: <span class="font-bold {{ \$strongswanStatus == 'active' ? 'text-green-600' : 'text-red-600' }}">{{ \$strongswanStatus }}</span></p>
        <p>XL2TPD: <span class="font-bold {{ \$xl2tpdStatus == 'active' ? 'text-green-600' : 'text-red-600' }}">{{ \$xl2tpdStatus }}</span></p>
    </div>
</div>
<div class="mt-4">
    <a href="{{ route('users') }}" class="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">Manage Users</a>
    <a href="{{ route('logs') }}" class="bg-gray-600 text-white px-4 py-2 rounded hover:bg-gray-700">View Logs</a>
</div>
@endsection
EOF

# View: users.blade.php
cat > /var/www/vpn_panel/resources/views/users.blade.php <<EOF
@extends('layouts.app')

@section('content')
<div class="bg-white p-4 rounded shadow">
    <h2 class="text-lg font-semibold mb-4">Add New User</h2>
    <form action="{{ route('addUser') }}" method="POST" class="flex space-x-4">
        @csrf
        <input type="text" name="username" placeholder="Username" class="border p-2 rounded" required>
        <input type="password" name="password" placeholder="Password" class="border p-2 rounded" required>
        <input type="date" name="expires_at" placeholder="Expiration Date" class="border p-2 rounded">
        <input type="number" name="connection_limit" placeholder="Connection Limit" class="border p-2 rounded">
        <button type="submit" class="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">Add User</button>
    </form>
</div>
<div class="mt-4 bg-white p-4 rounded shadow">
    <h2 class="text-lg font-semibold mb-4">User List</h2>
    <table class="w-full table-auto">
        <thead>
            <tr class="bg-gray-200">
                <th class="px-4 py-2">Username</th>
                <th class="px-4 py-2">Created</th>
                <th class="px-4 py-2">Expires</th>
                <th class="px-4 py-2">Connections</th>
                <th class="px-4 py-2">Actions</th>
            </tr>
        </thead>
        <tbody>
            @foreach (\$users as \$user)
            <tr>
                <td class="border px-4 py-2">{{ \$user->username }}</td>
                <td class="border px-4 py-2">{{ \$user->created_at }}</td>
                <td class="border px-4 py-2">{{ \$user->expires_at ?? 'None' }}</td>
                <td class="border px-4 py-2">{{ \$user->connections_used }}/{{ \$user->connection_limit }}</td>
                <td class="border px-4 py-2">
                    <form action="{{ route('editUser', \$user) }}" method="POST" class="inline">
                        @csrf
                        @method('PATCH')
                        <input type="password" name="password" placeholder="New Password" class="border p-1 rounded">
                        <button type="submit" class="bg-yellow-600 text-white px-2 py-1 rounded hover:bg-yellow-700">Edit</button>
                    </form>
                    <form action="{{ route('deleteUser', \$user) }}" method="POST" class="inline">
                        @csrf
                        @method('DELETE')
                        <button type="submit" onclick="return confirm('Are you sure?')" class="bg-red-600 text-white px-2 py-1 rounded hover:bg-red-700">Delete</button>
                    </form>
                </td>
            </tr>
            @endforeach
        </tbody>
    </table>
</div>
@endsection
EOF

# View: login.blade.php
cat > /var/www/vpn_panel/resources/views/login.blade.php <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Admin Login</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-100 flex items-center justify-center h-screen">
    <div class="bg-white p-8 rounded shadow-md w-full max-w-md">
        <h1 class="text-2xl font-bold mb-4 text-center">Admin Login</h1>
        @if (\$errors->any())
        <p class="text-red-600 mb-4">{{ \$errors->first() }}</p>
        @endif
        <form method="POST" action="{{ route('loginPost') }}">
            @csrf
            <div class="mb-4">
                <label for="username" class="block text-sm font-medium">Username</label>
                <input type="text" id="username" name="username" class="w-full border p-2 rounded" required>
            </div>
            <div class="mb-4">
                <label for="password" class="block text-sm font-medium">Password</label>
                <input type="password" id="password" name="password" class="w-full border p-2 rounded" required>
            </div>
            <button type="submit" class="w-full bg-blue-600 text-white p-2 rounded hover:bg-blue-700">Login</button>
        </form>
    </div>
</body>
</html>
EOF

# View: logs.blade.php
cat > /var/www/vpn_panel/resources/views/logs.blade.php <<EOF
@extends('layouts.app')

@section('content')
<div class="bg-white p-4 rounded shadow">
    <h2 class="text-lg font-semibold mb-4">VPN Connection Logs</h2>
    <pre class="bg-gray-100 p-4 rounded">
@foreach (\$logs as \$log)
{{ \$log }}
@endforeach
    </pre>
</div>
@endsection
EOF

# Routes: web.php
cat > /var/www/vpn_panel/routes/web.php <<EOF
<?php
use App\Http\Controllers\VpnController;
use Illuminate\Support\Facades\Route;

Route::get('/login', [VpnController::class, 'login'])->name('login');
Route::post('/login', [VpnController::class, 'loginPost'])->name('loginPost');
Route::get('/logout', [VpnController::class, 'logout'])->name('logout');

Route::middleware('auth:admin')->group(function () {
    Route::get('/', [VpnController::class, 'dashboard'])->name('dashboard');
    Route::get('/users', [VpnController::class, 'users'])->name('users');
    Route::post('/users', [VpnController::class, 'addUser'])->name('addUser');
    Route::patch('/users/{user}', [VpnController::class, 'editUser'])->name('editUser');
    Route::delete('/users/{user}', [VpnController::class, 'deleteUser'])->name('deleteUser');
    Route::get('/logs', [VpnController::class, 'logs'])->name('logs');
});
EOF

# Auth config: auth.php
cat > /var/www/vpn_panel/config/auth.php <<EOF
<?php
return [
    'defaults' => [
        'guard' => 'web',
        'passwords' => 'users',
    ],
    'guards' => [
        'web' => [
            'driver' => 'session',
            'provider' => 'users',
        ],
        'admin' => [
            'driver' => 'session',
            'provider' => 'admins',
        ],
    ],
    'providers' => [
        'users' => [
            'driver' => 'eloquent',
            'model' => App\Models\User::class,
        ],
        'admins' => [
            'driver' => 'eloquent',
            'model' => App\Models\Admin::class,
        ],
    ],
    'passwords' => [
        'users' => [
            'provider' => 'users',
            'table' => 'password_resets',
            'expire' => 60,
        ],
    ],
];
EOF

# Setup Nginx
cat > /etc/nginx/sites-available/vpn_panel <<EOF
server {
    listen 80;
    server_name localhost;
    root /var/www/vpn_panel/public;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/vpn_panel /etc/nginx/sites-enabled/
systemctl restart nginx || { echo "Warning: Failed to restart nginx"; exit 1; }

# Run migrations
cd /var/www/vpn_panel
php artisan migrate || { echo "Failed to run migrations"; exit 1; }

# Set permissions for chap-secrets
chmod 600 /etc/ppp/chap-secrets
chown www-data:www-data /etc/ppp/chap-secrets

echo "Installation complete! Access the panel at http://your_server_ip"
echo "Default admin login: admin / admin123"
