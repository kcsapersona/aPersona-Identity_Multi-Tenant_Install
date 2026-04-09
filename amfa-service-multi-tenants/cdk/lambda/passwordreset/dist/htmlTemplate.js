"use strict";var n=Object.defineProperty;var m=Object.getOwnPropertyDescriptor;var s=Object.getOwnPropertyNames;var g=Object.prototype.hasOwnProperty;var c=(t,e)=>{for(var i in e)n(t,i,{get:e[i],enumerable:!0})},p=(t,e,i,o)=>{if(e&&typeof e=="object"||typeof e=="function")for(let l of s(e))!g.call(t,l)&&l!==i&&n(t,l,{get:()=>e[l],enumerable:!(o=m(e,l))||o.enumerable});return t};var r=t=>p(n({},"__esModule",{value:!0}),t);var f={};c(f,{default:()=>b});module.exports=r(f);var v=(t,e,i,o,l,h)=>{let d=`<p>Your following MFA value${e.length>1?"s":""} has been changed${l?" by Admin":""}.</p>`;for(let a=0;a<e.length;a++)d+=`<p>&nbsp;&nbsp;&#x2022; ${e[a]} has been `,d+=i[a]&&i[a].length>1?"changed to "+i[a]:"removed",d+="</p>";return console.log("HTML template diff value",d),`
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
							<img src="${o}" alt="logo" />
						</div>
						<div class="email">
							<div>
								<h1>MFA value changed</h1>
							</div>
							<div class="email-body">
								<p>Hello ${t},</p>
								${d}
								<p>If you did not make this change, please contact the help desk.</p>
							</div>
							<div class="email-footer">
								<p>${h}</p>
							</div>
						</div>
					</div>
				</body>
			</html>
	`},b=v;
//# sourceMappingURL=htmlTemplate.js.map
