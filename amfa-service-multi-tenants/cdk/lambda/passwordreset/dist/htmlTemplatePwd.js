"use strict";var r=Object.defineProperty;var s=Object.getOwnPropertyDescriptor;var d=Object.getOwnPropertyNames;var l=Object.prototype.hasOwnProperty;var m=(o,e)=>{for(var t in e)r(o,t,{get:e[t],enumerable:!0})},n=(o,e,t,a)=>{if(e&&typeof e=="object"||typeof e=="function")for(let i of d(e))!l.call(o,i)&&i!==t&&r(o,i,{get:()=>e[i],enumerable:!(a=s(e,i))||a.enumerable});return o};var h=o=>n(r({},"__esModule",{value:!0}),o);var c={};m(c,{default:()=>y});module.exports=h(c);var p=(o,e,t,a)=>`
		<!DOCTYPE html >
			<html>
				<head>
					<meta charset="utf-8">
						<title>Email Title</title>
						<style>
							.container {
								width: 95%;
								box-shadow: 0 0.5em 1em 0 rgba(0,0,0,0.2);
								margin: 2em auto;
								border-radius: 0.5em;

							}
							.email {
								padding: 1em 4em;
							}
							.email-body {
								padding-top: 0.5em;
							}
							.email-footer {
								text-align: center;
							}
							.logo {
								text-align: center;
							}
							img {
								height: 57px;
								width: 313px;
							}
						</style>
				</head>
				<body>
					<div class="container">
						<div class="logo">
							<img src="${e}" alt="logo" />
						</div>
						<div class="email">
							<div>
								<h1>Password changed</h1>
							</div>
							<div class="email-body">
								<p>Hello ${o},</p>
								<p>The password on your account has recently been reset${a?" by Admin":""}. If you performed this password reset, then this message is for your information only.</p>
								<br/>
								<p>If you are not sure you or your administrator performed this password reset, then you should contact your administrator immediately or change your password yourself.</p>
							</div>
							<div class="email-footer">
								<p>${t}</p>
							</div>
						</div>
					</div>
				</body>
			</html>
	`,y=p;
//# sourceMappingURL=htmlTemplatePwd.js.map
