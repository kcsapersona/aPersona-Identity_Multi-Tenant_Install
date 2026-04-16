"use strict";var n=Object.defineProperty;var r=Object.getOwnPropertyDescriptor;var s=Object.getOwnPropertyNames;var l=Object.prototype.hasOwnProperty;var p=(e,t)=>{for(var o in t)n(e,o,{get:t[o],enumerable:!0})},c=(e,t,o,a)=>{if(t&&typeof t=="object"||typeof t=="function")for(let i of s(t))!l.call(e,i)&&i!==o&&n(e,i,{get:()=>t[i],enumerable:!(a=r(t,i))||a.enumerable});return e};var m=e=>c(n({},"__esModule",{value:!0}),e);var f={};p(f,{templateInvite:()=>y,templateReset:()=>v});module.exports=m(f);var d=e=>`  <html>
  <head>
  <meta charset="utf-8">
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
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">
        <img
        alt="logo"
        src="${e}"
        style="height: 57px; width: 313px"
      />
    </div>
    <div class="email">
      `,u=(e,t,o)=>`
  <div class="email-body">
    <p>Hi ${e||t}&#44</p>
    <br/>
    <p>${o} has created a new account for you.</p>
    <p>Your login id is ${t}. Please use it to login and set up your new account.</span></p>
  </div>`,g=e=>`
    <div style = "text-align: center; font-size: 12pt; padding: 1em" >
      <a href="${e}" style="text-decoration: none; color: #fff;padding: 0.5em 1.5em; background-color:#06AA6D; border-radius: 0.3em"> Login </a>
    </div >`,y=(e,t,o,a)=>d(o.email_logo_url)+u(e,t,o.service_name)+g(a),b=e=>`
    <div style="text-align: center; font-size: 12pt; padding: 1em">
      <a href="${e}" style="text-decoration: none; color: #fff;padding: 0.5em 1.5em; background-color:#06AA6D; border-radius: 0.3em"> Login </a>
    </div>`,h=(e,t)=>`
    <p>Hi ${e||t}&#44</p>
    <br/>
    <p>Please be advised that your account password has been reset for security reasons.</p>
    <p>The next time you login, you will be required to update your password.</p>
`,v=(e,t,o,a)=>d(o.email_logo_url)+h(e,t)+b(a);0&&(module.exports={templateInvite,templateReset});
//# sourceMappingURL=templates.js.map
