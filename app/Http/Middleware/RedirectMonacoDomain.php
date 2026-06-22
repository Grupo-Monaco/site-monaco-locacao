<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;

class RedirectMonacoDomain
{
    public function handle(Request $request, Closure $next)
    {
        if ($request->getHost() === 'monacolocacao.com.br') {
            return redirect()->away(
                'https://gidlocacao.com.br' . $request->getRequestUri(),
                301
            );
        }

        return $next($request);
    }
}